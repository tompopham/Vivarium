// Reader — a read-only Markdown viewer that follows the system light/dark setting live.
//
// Each document opens in a window holding a WKWebView. The page (web/reader.html) renders
// with marked, KaTeX and highlight.js, all bundled so nothing is fetched. Its colours come from
// prefers-color-scheme, which WebKit re-evaluates the moment the app's appearance changes —
// the thing Typora does not do. The file is watched and re-rendered in place on every save,
// so the scroll position survives edits made in another app. Editing happens elsewhere:
// "Open in Editor" (⌘E) hands the file to Typora, or whichever app is chosen.

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

    static func open(_ url: URL) {
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
        } else {
            NSWorkspace.shared.open(target)
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
/// proxy icon and window restoration. It never holds or saves content: the window reads the
/// file straight from disk each time it changes.
@objc(MarkdownDocument)
final class MarkdownDocument: NSDocument {
    override class var autosavesInPlace: Bool { false }
    override var isDocumentEdited: Bool { false }

    override func read(from url: URL, ofType typeName: String) throws {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw CocoaError(.fileReadNoPermission, userInfo: [NSURLErrorKey: url])
        }
    }

    override func makeWindowControllers() {
        addWindowController(ReaderWindowController())
    }

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        guard let controller = windowControllers.first as? ReaderWindowController else {
            throw CocoaError(.featureUnsupported)
        }
        return controller.printOperation(printInfo: printInfo)
    }
}

// MARK: - Window

/// Lets a click on a link in a window that is not in front follow the link straight away,
/// instead of only bringing the window forward.
final class ReaderWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class ReaderWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
                                    WKNavigationDelegate, WKUIDelegate {
    private let webView: ReaderWebView
    private let searchItem = NSSearchToolbarItem(itemIdentifier: .search)
    private var watcher: FileWatcher?
    private var pageLoaded = false

    init() {
        webView = ReaderWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Prefs.windowSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 360, height: 300)
        window.backgroundColor = .textBackgroundColor
        window.toolbarStyle = .unifiedCompact
        window.tabbingMode = .preferred
        super.init(window: window)

        webView.setValue(false, forKey: "drawsBackground")  // no white flash in dark mode
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsMagnification = true
        webView.pageZoom = Prefs.zoom
        window.contentView = webView
        window.delegate = self

        let toolbar = NSToolbar(identifier: "Reader")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar

        searchItem.searchField.placeholderString = "Find"
        searchItem.searchField.sendsWholeSearchString = true
        searchItem.searchField.target = self
        searchItem.searchField.action = #selector(findNext(_:))

        let page = Bundle.main.url(forResource: "reader", withExtension: "html", subdirectory: "web")!
        webView.loadFileURL(page, allowingReadAccessTo: URL(fileURLWithPath: "/"))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var document: AnyObject? {
        didSet {
            guard document != nil else { return }
            watcher = FileWatcher(url: { [weak self] in (self?.document as? NSDocument)?.fileURL },
                                  onChange: { [weak self] in self?.render() })
            render()
        }
    }

    private var fileURL: URL? { (document as? NSDocument)?.fileURL }

    private func render() {
        guard pageLoaded, let url = fileURL, let data = try? Data(contentsOf: url) else { return }
        webView.callAsyncJavaScript("render(markdown, base)",
                                    arguments: ["markdown": String(decoding: data, as: UTF8.self),
                                                "base": url.deletingLastPathComponent().absoluteString],
                                    in: nil, in: .page) { result in
            if case .failure(let error) = result { NSLog("Reader: render failed: \(error)") }
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

    // MARK: Actions

    @objc func openInEditor(_ sender: Any?) {
        guard let url = fileURL else { return }
        NSWorkspace.shared.open([url], withApplicationAt: Prefs.editor, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func showInFinder(_ sender: Any?) {
        guard let url = fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func reload(_ sender: Any?) { render() }

    @objc func showFind(_ sender: Any?) {
        searchItem.beginSearchInteraction()
    }

    @objc func findNext(_ sender: Any?) { find(backwards: false) }
    @objc func findPrevious(_ sender: Any?) { find(backwards: true) }

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

    // MARK: NSWindowDelegate

    func windowDidEndLiveResize(_ notification: Notification) {
        if let size = window?.frame.size { Prefs.windowSize = size }
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
            Links.open(url)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { Links.open(url) }  // target="_blank"
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        pageLoaded = false
        webView.reload()
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .editor, .search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case .search:
            return searchItem
        case .editor:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Open in Editor"
            item.toolTip = "Open in \(FileManager.default.displayName(atPath: Prefs.editor.path)) (⌘E)"
            item.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "Open in Editor")
            item.isBordered = true
            item.target = self
            item.action = #selector(openInEditor(_:))
            return item
        default:
            return nil
        }
    }
}

extension NSToolbarItem.Identifier {
    static let search = Self("search")
    static let editor = Self("editor")
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    func applicationWillFinishLaunching(_ notification: Notification) {
        _ = NSDocumentController.shared
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

    @objc func setAppearance(_ sender: NSMenuItem) {
        Prefs.appearance = sender.representedObject as? String ?? "system"
        Prefs.applyAppearance()
    }

    @objc func chooseEditor(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.message = "Choose the app ⌘E opens files in"
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
            item.title = "Editor: \(FileManager.default.displayName(atPath: Prefs.editor.path))…"
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
                  _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = target
            return item
        }

        _ = submenu("Reader", [
            item("About Reader", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Editor…", #selector(chooseEditor(_:)), target: self),
            .separator(),
            item("Hide Reader", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit Reader", #selector(NSApplication.terminate(_:)), "q"),
        ])

        let recent = NSMenu(title: "Open Recent")
        recent.addItem(item("Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:))))
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recentItem.submenu = recent
        _ = submenu("File", [
            item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"),
            recentItem,
            .separator(),
            item("Open in Editor", #selector(ReaderWindowController.openInEditor(_:)), "e"),
            item("Show in Finder", #selector(ReaderWindowController.showInFinder(_:)), "r", [.command, .shift]),
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Print…", #selector(NSDocument.printDocument(_:)), "p"),
        ])

        _ = submenu("Edit", [
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Find…", #selector(ReaderWindowController.showFind(_:)), "f"),
            item("Find Next", #selector(ReaderWindowController.findNext(_:)), "g"),
            item("Find Previous", #selector(ReaderWindowController.findPrevious(_:)), "g", [.command, .shift]),
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
            item("Actual Size", #selector(ReaderWindowController.actualSize(_:)), "0"),
            item("Zoom In", #selector(ReaderWindowController.zoomIn(_:)), "="),
            item("Zoom Out", #selector(ReaderWindowController.zoomOut(_:)), "-"),
            .separator(),
            appearanceItem,
            .separator(),
            item("Reload", #selector(ReaderWindowController.reload(_:)), "r"),
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
