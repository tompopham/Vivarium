# Reader

A read-only Markdown viewer for macOS. Personal replacement for reading in Typora, which doesn't
follow the system light/dark switch live. Reader does: colours come from CSS
`prefers-color-scheme`, which WebKit re-evaluates the moment macOS changes appearance.

- Renders GitHub-flavoured Markdown (tables, task lists), LaTeX maths (`$…$`, `$$…$$`, `\(…\)`,
  `\[…\]`) with KaTeX, and fenced code with highlight.js. All bundled — nothing is fetched.
- Re-renders in place whenever the file changes on disk, keeping the scroll position.
- ⌘E opens the file in an editor (Typora by default; Reader › Editor… to change).
- Obsidian `[[wikilinks]]` resolve anywhere in the vault; other links open in their own apps.
- YAML front matter is shown as a dim block. Scripts in documents never run (CSP).

Keys: ⌘O open, ⌘E editor, ⌘F / ⌘G find, ⌘= / ⌘- / ⌘0 zoom, ⌘R reload, ⇧⌘R show in Finder, ⌘P print.
View › Appearance overrides the system setting.

## Build & install
    ./build.sh            # builds build/Reader.app
    ./build.sh --install  # builds, replaces /Applications/Reader.app, opens it

Requires the Xcode command line tools. Apple-silicon only as written.

## Files
- `main.swift` — the app (document windows, file watching, menus)
- `web/` — the page: `reader.html`, `reader.js` (Markdown → HTML), `reader.css`, and `vendor/`
  (marked 18.0.14, KaTeX 0.18.9, highlight.js 11.12.0, with their licences)
- `make-icon.swift` — draws `AppIcon.icns`; run once with `swift make-icon.swift`
