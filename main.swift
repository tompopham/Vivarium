// Vivarium — a Markdown reader and editor that follows the system light/dark setting live.
//
// Each document opens in a window holding a WKWebView. The page (web/reader.html) renders
// with marked, KaTeX and highlight.js, all bundled so nothing is fetched. Its colours come from
// prefers-color-scheme, which WebKit re-evaluates the moment the app's appearance changes —
// the thing Typora does not do. The file is watched and re-rendered in place on every save,
// so the scroll position survives edits made in another app. ⌘E opens the Markdown source
// beside the page for editing; the page follows as you type and the file saves itself.
//
// Named after the Vivarium, the monastery Cassiodorus founded for monks to read and copy
// manuscripts.

import AppKit
import UniformTypeIdentifiers
import WebKit

// MARK: - Preferences

enum Prefs {
    static let defaults = UserDefaults.standard

    static var zoom: CGFloat {
        get { defaults.object(forKey: "zoom") as? CGFloat ?? 1 }
        set { defaults.set(newValue, forKey: "zoom") }
    }

    /// "system", "light" or "dark".
    static var appearance: String {
        get { defaults.string(forKey: "appearance") ?? "system" }
        set { defaults.set(newValue, forKey: "appearance") }
    }

    static var windowSize: NSSize {
        get { defaults.string(forKey: "windowSize").map(NSSizeFromString) ?? NSSize(width: 820, height: 940) }
        set { defaults.set(NSStringFromSize(newValue), forKey: "windowSize") }
    }

    /// The editor ⌘E opens: the chosen app, else Typora, else TextEdit.
    static var editor: URL {
        get {
            if let path = defaults.string(forKey: "editorPath"), FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "abnerworks.Typora")
                ?? URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        }
        set { defaults.set(newValue.path, forKey: "editorPath") }
    }

    static func applyAppearance() {
        switch appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}

// MARK: - File watching

/// Calls back when the file changes on disk. Editors often save by writing a new file and
/// renaming it over the old one, which leaves a watched descriptor pointing at the old file,
/// so on delete or rename the watch is re-armed on whatever is at the path now.
final class FileWatcher {
    private let url: () -> URL?
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    init(url: @escaping () -> URL?, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        arm()
    }

    deinit { source?.cancel() }

    private func arm(attempt: Int = 0) {
        source?.cancel()
        source = nil
        guard let path = url()?.path else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // Mid-save, the file can briefly not exist. Give up after about 5 s (deleted).
            if attempt < 25 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.arm(attempt: attempt + 1) }
            }
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                               eventMask: [.write, .extend, .delete, .rename, .revoke],
                                                               queue: .main)
        source.setEventHandler { [weak self, unowned source] in
            guard let self else { return }
            if !source.data.isDisjoint(with: [.delete, .rename, .revoke]) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.arm() }
            }
            self.changed()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    /// Coalesces the burst of events one save produces into one reload.
    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }
}

// MARK: - Links

enum Links {
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mdwn"]

    static func isMarkdown(_ url: URL) -> Bool { markdownExtensions.contains(url.pathExtension.lowercased()) }

    /// Opens a link's target. `window` is the window the link was clicked in, for the sheet
    /// that asks before opening an app or script.
    static func open(_ url: URL, from window: NSWindow? = nil) {
        guard url.isFileURL else {
            NSWorkspace.shared.open(url)
            return
        }
        var target = URL(fileURLWithPath: url.path)  // drops any #fragment
        let fm = FileManager.default
        if !fm.fileExists(atPath: target.path), let found = findNote(named: target.lastPathComponent,
                                                                     near: target.deletingLastPathComponent()) {
            target = found
        }
        guard fm.fileExists(atPath: target.path) else {
            NSSound.beep()
            return
        }
        if isMarkdown(target) {
            NSDocumentController.shared.openDocument(withContentsOf: target, display: true) { _, _, _ in }
        } else if canRunCode(target) {
            confirmOpening(target, from: window)
        } else {
            NSWorkspace.shared.open(target)
        }
    }

    /// Kinds of file that run something when opened: apps and other programs, scripts
    /// (Python's and Ruby's count as shell scripts), Terminal's .command, .tool and .terminal
    /// files, and .fileloc files, which open whatever they point at.
    private static let runnableTypes: [UTType] = [.application, .executable, .shellScript]
        + ["com.apple.terminal.shell-script", "com.apple.terminal.settings", "com.apple.file-internet-location"]
            .compactMap { UTType($0) }

    /// Whether opening the file could run code. A file marked executable counts too unless it
    /// is a known kind of document, since files copied from USB sticks and network drives
    /// are often marked executable.
    static func canRunCode(_ url: URL) -> Bool {
        // An alias or symlink opens whatever it points at, so look at that.
        let url = (try? URL(resolvingAliasFileAt: url)) ?? url
        guard let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isApplicationKey,
                                                              .isExecutableKey, .isDirectoryKey])
        else { return true }
        if values.isApplication == true { return true }
        if let type = values.contentType, runnableTypes.contains(where: type.conforms(to:)) { return true }
        guard values.isExecutable == true, values.isDirectory != true else { return false }
        return !(values.contentType.map { $0.conforms(to: .content) || $0.conforms(to: .archive) } ?? false)
    }

    /// A link is easy to click without looking where it goes, so an app or script is only
    /// opened once asked. Return shows it in Finder; Open must be chosen deliberately.
    private static func confirmOpening(_ url: URL, from window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Open \(url.lastPathComponent)?"
        alert.informativeText = "It can run commands on this Mac."
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "Open").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let respond = { (response: NSApplication.ModalResponse) in
            switch response {
            case .alertFirstButtonReturn: NSWorkspace.shared.activateFileViewerSelecting([url])
            case .alertSecondButtonReturn: NSWorkspace.shared.open(url)
            default: break
            }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(alert.runModal())
        }
    }

    /// A [[wikilink]] names a note, not a path. Search the Obsidian vault the file is in (the
    /// nearest folder above it holding .obsidian), or failing that the file's own folder.
    private static func findNote(named name: String, near folder: URL) -> URL? {
        let fm = FileManager.default
        var root = folder
        var probe = folder
        for _ in 0..<10 {
            if fm.fileExists(atPath: probe.appendingPathComponent(".obsidian").path) {
                root = probe
                break
            }
            let parent = probe.deletingLastPathComponent()
            if parent.path == probe.path { break }
            probe = parent
        }
        guard let files = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        for case let file as URL in files where file.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame {
            return file
        }
        return nil
    }
}

// MARK: - Document

/// NSDocument supplies the Open panel, Open Recent, one window per file, the title bar's
/// proxy icon, window restoration, and saving: edits autosave in place, with the usual
/// Versions history behind File › Revert to Saved.
@objc(MarkdownDocument)
final class MarkdownDocument: NSDocument {
    var text = ""
    /// Called whenever `text` is replaced from disk: on opening, and on reverting after
    /// another app changed the file.
    var onLoad: (() -> Void)?

    override class var autosavesInPlace: Bool { true }

    override func read(from data: Data, ofType typeName: String) throws {
        text = String(decoding: data, as: UTF8.self)
        if Thread.isMainThread { onLoad?() } else { DispatchQueue.main.async { self.onLoad?() } }
    }

    override func data(ofType typeName: String) throws -> Data { Data(text.utf8) }

    override func makeWindowControllers() {
        addWindowController(DocumentWindowController())
    }

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        guard let controller = windowControllers.first as? DocumentWindowController else {
            throw CocoaError(.featureUnsupported)
        }
        return controller.printOperation(printInfo: printInfo)
    }

    func saveNow() {
        guard isDocumentEdited else { return }
        autosave(withImplicitCancellability: false) { error in
            if let error { NSLog("Vivarium: save failed: \(error)") }
        }
    }
}

// MARK: - Page pool

/// Starting WebKit's helper processes takes about a second, far longer than rendering does.
/// So a page is loaded ahead of time — at launch, and again after each window takes one —
/// and a new window starts with a page that is already loaded.
enum PagePool {
    private static var spare: PageWebView?

    static func prepare() {
        if spare == nil { spare = make() }
    }

    static func take() -> PageWebView {
        let view = spare ?? make()
        spare = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { prepare() }
        return view
    }

    private static func make() -> PageWebView {
        let view = PageWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 800),
                                 configuration: WKWebViewConfiguration())
        view.setValue(false, forKey: "drawsBackground")  // no white flash in dark mode
        view.loadPage()
        return view
    }
}

// MARK: - Window

final class PageWebView: WKWebView {
    /// Lets a click on a link in a window that is not in front follow the link straight away,
    /// instead of only bringing the window forward.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Loads the bundled page, empty until the app renders a document into it.
    func loadPage() {
        let page = Bundle.main.url(forResource: "reader", withExtension: "html", subdirectory: "web")!
        loadFileURL(page, allowingReadAccessTo: URL(fileURLWithPath: "/"))
    }
}

/// Reading shows the rendered page alone. Editing (⌘E) opens the Markdown source to its
/// left; the page re-renders as you type and follows the source's scroll position.
final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation,
                                    WKNavigationDelegate, WKUIDelegate, NSTextViewDelegate {
    private let webView: PageWebView
    private let splitView = NSSplitView()
    private let sourceScroll = NSTextView.scrollableTextView()
    private var sourceView: NSTextView { sourceScroll.documentView as! NSTextView }
    private let searchItem = NSSearchToolbarItem(itemIdentifier: .search)
    private var editItem: NSToolbarItem?
    private var watcher: FileWatcher?
    private var pageLoaded = false
    private var pendingRender: DispatchWorkItem?
    private var pendingSave: DispatchWorkItem?
    private var widthBeforeEditing: CGFloat?
    private(set) var isEditing = false
    private var waitingToShow = false
    private var hasRendered = false
    private var lastCrash = Date.distantPast

    init() {
        webView = PagePool.take()
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Prefs.windowSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 360, height: 300)
        window.backgroundColor = .textBackgroundColor
        window.toolbarStyle = .unifiedCompact
        window.tabbingMode = .preferred
        super.init(window: window)

        webView.navigationDelegate = self
        webView.uiDelegate = self
        pageLoaded = !webView.isLoading && webView.url != nil
        webView.allowsMagnification = true
        webView.pageZoom = Prefs.zoom

        let source = sourceView
        source.delegate = self
        source.isRichText = false
        source.importsGraphics = false
        source.allowsUndo = true
        source.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        source.textColor = .textColor
        source.backgroundColor = .textBackgroundColor
        source.textContainerInset = NSSize(width: 14, height: 20)
        source.isAutomaticQuoteSubstitutionEnabled = false
        source.isAutomaticDashSubstitutionEnabled = false
        source.isAutomaticTextReplacementEnabled = false
        source.isAutomaticSpellingCorrectionEnabled = false
        source.isContinuousSpellCheckingEnabled = true
        source.usesFindBar = true
        source.isIncrementalSearchingEnabled = true
        sourceScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(sourceScrolled(_:)),
                                               name: NSView.boundsDidChangeNotification, object: sourceScroll.contentView)

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(webView)
        window.contentView = splitView
        splitView.adjustSubviews()
        window.delegate = self

        let toolbar = NSToolbar(identifier: "Vivarium")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar

        searchItem.searchField.placeholderString = "Find"
        searchItem.searchField.sendsWholeSearchString = true
        searchItem.searchField.target = self
        searchItem.searchField.action = #selector(findNext(_:))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var document: AnyObject? {
        didSet {
            guard let doc = markdown else { return }
            doc.onLoad = { [weak self] in self?.documentLoaded() }
            watcher = FileWatcher(url: { [weak doc] in doc?.fileURL },
                                  onChange: { [weak self] in self?.fileChangedOnDisk() })
            documentLoaded()
            if doc.fileURL == nil {  // File › New starts in the editor
                DispatchQueue.main.async { self.setEditing(true) }
            }
        }
    }

    private var markdown: MarkdownDocument? { document as? MarkdownDocument }

    /// Holds the window back until the page has its content (or a second has passed),
    /// so it opens showing the document rather than an empty frame.
    override func showWindow(_ sender: Any?) {
        guard !hasRendered else { return super.showWindow(sender) }
        waitingToShow = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.showIfWaiting() }
    }

    private func showIfWaiting() {
        guard waitingToShow else { return }
        waitingToShow = false
        super.showWindow(nil)
    }

    /// The document's text was replaced from disk: show it in the source view and the page.
    private func documentLoaded() {
        guard let doc = markdown else { return }
        if sourceView.string != doc.text {
            let caret = sourceView.selectedRange().location
            sourceView.string = doc.text
            doc.undoManager?.removeAllActions()  // undo steps would point into the old text
            sourceView.setSelectedRange(NSRange(location: min(caret, (doc.text as NSString).length), length: 0))
        }
        render()
    }

    /// Another app (or this one's own save) changed the file. Reload it unless there are
    /// unsaved edits here; in that case NSDocument asks which version to keep when it next saves.
    private func fileChangedOnDisk() {
        guard let doc = markdown, let url = doc.fileURL, let data = try? Data(contentsOf: url) else { return }
        guard String(decoding: data, as: UTF8.self) != doc.text, !doc.isDocumentEdited else { return }
        do {
            try doc.revert(toContentsOf: url, ofType: doc.fileType ?? "net.daringfireball.markdown")
        } catch {
            NSLog("Vivarium: reload failed: \(error)")
        }
    }

    private func render() {
        guard pageLoaded, let doc = markdown else { return }
        let folder = doc.fileURL?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser
        webView.callAsyncJavaScript("render(markdown, base)",
                                    arguments: ["markdown": doc.text, "base": folder.absoluteString],
                                    in: nil, in: .page) { [weak self] result in
            if case .failure(let error) = result { NSLog("Vivarium: render failed: \(error)") }
            self?.hasRendered = true
            self?.showIfWaiting()
            if self?.isEditing == true { self?.syncScroll() }
        }
    }

    func printOperation(printInfo: NSPrintInfo) -> NSPrintOperation {
        printInfo.horizontalPagination = .fit
        printInfo.isVerticallyCentered = false
        printInfo.topMargin = 36
        printInfo.bottomMargin = 36
        printInfo.leftMargin = 42
        printInfo.rightMargin = 42
        let operation = webView.printOperation(with: printInfo)
        operation.view?.frame = webView.bounds  // without a frame WebKit prints blank pages
        return operation
    }

    // MARK: Editing

    @objc func toggleEditing(_ sender: Any?) { setEditing(!isEditing) }

    private func setEditing(_ editing: Bool) {
        guard editing != isEditing, let window else { return }
        isEditing = editing
        let fullScreen = window.styleMask.contains(.fullScreen)
        if editing {
            splitView.insertArrangedSubview(sourceScroll, at: 0)
            // Widen the window so the page keeps a readable width beside the source.
            var frame = window.frame
            let screen = window.screen?.visibleFrame ?? frame
            let wanted = min(max(frame.width, 1320), screen.width)
            if !fullScreen && wanted > frame.width {
                widthBeforeEditing = frame.width
                frame.origin.x = max(screen.minX, min(frame.midX - wanted / 2, screen.maxX - wanted))
                frame.size.width = wanted
                window.setFrame(frame, display: true, animate: true)
            }
            splitView.layoutSubtreeIfNeeded()
            splitView.setPosition(splitView.bounds.width / 2, ofDividerAt: 0)
            window.makeFirstResponder(sourceView)
            syncScroll()
        } else {
            markdown?.saveNow()
            sourceScroll.removeFromSuperview()
            splitView.adjustSubviews()
            if let width = widthBeforeEditing, !fullScreen {
                var frame = window.frame
                frame.origin.x = frame.midX - width / 2
                frame.size.width = width
                window.setFrame(frame, display: true, animate: true)
            }
            widthBeforeEditing = nil
            window.makeFirstResponder(webView)
        }
        updateEditItem()
    }

    private func updateEditItem() {
        editItem?.label = isEditing ? "Done" : "Edit"
        editItem?.toolTip = isEditing ? "Stop editing (⌘E)" : "Edit the Markdown (⌘E)"
        editItem?.image = NSImage(systemSymbolName: isEditing ? "checkmark.circle" : "square.and.pencil",
                                  accessibilityDescription: editItem?.label)
    }

    func textDidChange(_ notification: Notification) {
        guard let doc = markdown else { return }
        doc.text = sourceView.string

        pendingRender?.cancel()
        let render = DispatchWorkItem { [weak self] in self?.render() }
        pendingRender = render
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: render)

        // Save a moment after typing stops, so other apps (and Claude) see the file current.
        pendingSave?.cancel()
        let save = DispatchWorkItem { [weak doc] in doc?.saveNow() }
        pendingSave = save
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: save)
    }

    private static let listItem = try! NSRegularExpression(pattern: #"^(\s*)(?:([-*+])|(\d+)([.)]))(\s+)(\[[ xX]\]\s+)?"#)

    /// Return inside a list item starts the next item (numbered lists count on, task boxes
    /// start unticked); Return on an empty item ends the list.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        let caret = textView.selectedRange()
        guard caret.length == 0 else { return false }
        let text = textView.string as NSString
        let lineStart = text.lineRange(for: NSRange(location: caret.location, length: 0)).location
        let line = text.substring(with: NSRange(location: lineStart, length: caret.location - lineStart)) as NSString
        guard let match = Self.listItem.firstMatch(in: line as String, range: NSRange(location: 0, length: line.length))
        else { return false }

        if match.range.length == line.length {
            textView.insertText("", replacementRange: NSRange(location: lineStart, length: line.length))
            return true
        }
        func group(_ i: Int) -> String {
            let range = match.range(at: i)
            return range.location == NSNotFound ? "" : line.substring(with: range)
        }
        let marker = group(2).isEmpty ? "\((Int(group(3)) ?? 0) + 1)\(group(4))" : group(2)
        let box = group(6).isEmpty ? "" : "[ ] "
        textView.insertText("\n\(group(1))\(marker)\(group(5))\(box)", replacementRange: caret)
        return true
    }

    @objc private func sourceScrolled(_ notification: Notification) {
        if isEditing { syncScroll() }
    }

    /// Scrolls the page to the same proportion of its height as the source view.
    private func syncScroll() {
        guard let documentView = sourceScroll.documentView else { return }
        let visible = sourceScroll.contentView.bounds
        let range = documentView.frame.height - visible.height
        let fraction = range > 0 ? min(max(visible.minY / range, 0), 1) : 0
        webView.evaluateJavaScript("window.scrollTo(0, \(fraction) * (document.documentElement.scrollHeight - innerHeight))")
    }

    // MARK: Actions

    @objc func openInEditor(_ sender: Any?) {
        guard let doc = markdown, let url = doc.fileURL else { return }
        doc.saveNow()
        NSWorkspace.shared.open([url], withApplicationAt: Prefs.editor, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func showInFinder(_ sender: Any?) {
        guard let url = markdown?.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func reload(_ sender: Any?) {
        if !pageLoaded && !webView.isLoading { webView.loadPage() }  // the page process died
        fileChangedOnDisk()
        render()
    }

    /// While typing in the source, Find searches the source; otherwise the page.
    private var findsInSource: Bool { isEditing && window?.firstResponder === sourceView }

    @objc func showFind(_ sender: Any?) {
        if findsInSource { sourceView.performTextFinderAction(sender) } else { searchItem.beginSearchInteraction() }
    }

    @objc func findNext(_ sender: Any?) {
        if findsInSource { sourceView.performTextFinderAction(sender) } else { find(backwards: false) }
    }

    @objc func findPrevious(_ sender: Any?) {
        if findsInSource { sourceView.performTextFinderAction(sender) } else { find(backwards: true) }
    }

    private func find(backwards: Bool) {
        let query = searchItem.searchField.stringValue
        guard !query.isEmpty else { return }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true
        webView.find(query, configuration: configuration) { result in
            if !result.matchFound { NSSound.beep() }
        }
    }

    @objc func zoomIn(_ sender: Any?) { setZoom(webView.pageZoom * 1.1) }
    @objc func zoomOut(_ sender: Any?) { setZoom(webView.pageZoom / 1.1) }
    @objc func actualSize(_ sender: Any?) { setZoom(1) }

    private func setZoom(_ zoom: CGFloat) {
        webView.pageZoom = min(max(zoom, 0.5), 3)
        Prefs.zoom = webView.pageZoom
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleEditing(_:)):
            item.title = isEditing ? "Stop Editing" : "Edit Markdown"
        case #selector(openInEditor(_:)):
            item.title = "Open in \(FileManager.default.displayName(atPath: Prefs.editor.path))"
            return markdown?.fileURL != nil
        case #selector(showInFinder(_:)):
            return markdown?.fileURL != nil
        default:
            break
        }
        return true
    }

    // MARK: NSWindowDelegate

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { markdown?.undoManager }

    func windowDidEndLiveResize(_ notification: Notification) {
        if !isEditing, let size = window?.frame.size { Prefs.windowSize = size }
    }

    // MARK: WKNavigationDelegate / WKUIDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
        render()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // The only navigation allowed is the initial load of the bundled page. Links open in
        // the right app (Markdown here, the rest in their own apps), never inside this view.
        if !pageLoaded && navigationAction.navigationType == .other {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            Links.open(url, from: window)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { Links.open(url, from: window) }  // target="_blank"
        return nil
    }

    /// WebKit's page process can die (a crash, or macOS reclaiming memory), leaving the view
    /// blank. Load the page afresh rather than reload(), which the policy above would cancel;
    /// didFinish then renders the document again. If it dies again within seconds the document
    /// itself is probably the cause, so stop there rather than loop; ⌘R tries again.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        pageLoaded = false
        defer { lastCrash = Date() }
        guard Date().timeIntervalSince(lastCrash) > 10 else {
            NSLog("Vivarium: the page process died again; not reloading until ⌘R")
            return
        }
        self.webView.loadPage()
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .edit, .search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case .search:
            return searchItem
        case .edit:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.isBordered = true
            item.target = self
            item.action = #selector(toggleEditing(_:))
            editItem = item
            updateEditItem()
            return item
        default:
            return nil
        }
    }
}

extension NSToolbarItem.Identifier {
    static let search = Self("search")
    static let edit = Self("edit")
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    func applicationWillFinishLaunching(_ notification: Notification) {
        _ = NSDocumentController.shared
        PagePool.prepare()
        Prefs.applyAppearance()
        NSApp.mainMenu = makeMenu()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched on its own (not by opening a file, not restoring windows): ask for a file.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if NSDocumentController.shared.documents.isEmpty {
                NSDocumentController.shared.openDocument(nil)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { NSDocumentController.shared.openDocument(nil) }
        return false
    }

    /// Switching to another app saves, so whatever reads the file next sees the edits.
    func applicationDidResignActive(_ notification: Notification) {
        for case let doc as MarkdownDocument in NSDocumentController.shared.documents { doc.saveNow() }
    }

    @objc func setAppearance(_ sender: NSMenuItem) {
        Prefs.appearance = sender.representedObject as? String ?? "system"
        Prefs.applyAppearance()
    }

    @objc func chooseEditor(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.message = "Choose the app “Open in…” (⇧⌘E) uses"
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Prefs.editor = url
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(setAppearance(_:)) {
            item.state = (item.representedObject as? String) == Prefs.appearance ? .on : .off
        }
        if item.action == #selector(chooseEditor(_:)) {
            item.title = "External Editor: \(FileManager.default.displayName(atPath: Prefs.editor.path))…"
        }
        return true
    }

    private func makeMenu() -> NSMenu {
        let main = NSMenu()

        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            main.addItem(holder)
            return menu
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "",
                  _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil,
                  tag: Int = 0) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = target
            item.tag = tag
            return item
        }

        _ = submenu("Vivarium", [
            item("About Vivarium", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("External Editor…", #selector(chooseEditor(_:)), target: self),
            .separator(),
            item("Hide Vivarium", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit Vivarium", #selector(NSApplication.terminate(_:)), "q"),
        ])

        let recent = NSMenu(title: "Open Recent")
        recent.addItem(item("Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:))))
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recentItem.submenu = recent
        _ = submenu("File", [
            item("New", #selector(NSDocumentController.newDocument(_:)), "n"),
            item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"),
            recentItem,
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Save", #selector(NSDocument.save(_:)), "s"),
            item("Duplicate", #selector(NSDocument.duplicate(_:)), "s", [.command, .shift]),
            item("Rename…", #selector(NSDocument.rename(_:))),
            item("Move To…", #selector(NSDocument.move(_:))),
            item("Revert to Saved", #selector(NSDocument.revertToSaved(_:))),
            .separator(),
            item("Open in Editor", #selector(DocumentWindowController.openInEditor(_:)), "e", [.command, .shift]),
            item("Show in Finder", #selector(DocumentWindowController.showInFinder(_:)), "r", [.command, .shift]),
            .separator(),
            item("Print…", #selector(NSDocument.printDocument(_:)), "p"),
        ])

        _ = submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Find…", #selector(DocumentWindowController.showFind(_:)), "f",
                 tag: NSTextFinder.Action.showFindInterface.rawValue),
            item("Find Next", #selector(DocumentWindowController.findNext(_:)), "g",
                 tag: NSTextFinder.Action.nextMatch.rawValue),
            item("Find Previous", #selector(DocumentWindowController.findPrevious(_:)), "g", [.command, .shift],
                 tag: NSTextFinder.Action.previousMatch.rawValue),
            .separator(),
            item("Check Spelling While Typing", #selector(NSTextView.toggleContinuousSpellChecking(_:))),
        ])

        let appearance = NSMenu(title: "Appearance")
        for (title, value) in [("Follow System", "system"), ("Light", "light"), ("Dark", "dark")] {
            let choice = item(title, #selector(setAppearance(_:)), target: self)
            choice.representedObject = value
            appearance.addItem(choice)
        }
        let appearanceItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        appearanceItem.submenu = appearance
        _ = submenu("View", [
            item("Edit Markdown", #selector(DocumentWindowController.toggleEditing(_:)), "e"),
            .separator(),
            item("Actual Size", #selector(DocumentWindowController.actualSize(_:)), "0"),
            item("Zoom In", #selector(DocumentWindowController.zoomIn(_:)), "="),
            item("Zoom Out", #selector(DocumentWindowController.zoomOut(_:)), "-"),
            .separator(),
            appearanceItem,
            .separator(),
            item("Reload", #selector(DocumentWindowController.reload(_:)), "r"),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])

        let window = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        NSApp.windowsMenu = window
        return main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
