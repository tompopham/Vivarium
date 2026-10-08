# Vivarium

A Markdown reader and editor for macOS. Personal replacement for Typora, which doesn't follow
the system light/dark switch live. Vivarium does: colours come from CSS `prefers-color-scheme`,
which WebKit re-evaluates the moment macOS changes appearance. Named after the Vivarium, the
monastery Cassiodorus founded for monks to read and copy manuscripts.

- Renders GitHub-flavoured Markdown (tables, task lists), LaTeX maths (`$…$`, `$$…$$`, `\(…\)`,
  `\[…\]`) with KaTeX, and fenced code with highlight.js. All bundled — nothing is fetched.
- Re-renders in place whenever the file changes on disk, keeping the scroll position.
- ⌘E edits: the Markdown source opens beside the page, which re-renders as you type and follows
  the source's scroll. Edits save themselves (a moment after typing stops, on leaving the app,
  on ⌘E and on close), with Versions history under File › Revert to Saved. Return continues
  lists, numbered and task lists included; Return on an empty item ends the list.
- If another app changes the file while it has no unsaved edits here, Vivarium reloads it.
- ⇧⌘E opens the file in an external editor (Vivarium › External Editor… to choose).
- Obsidian `[[wikilinks]]` resolve anywhere in the vault; other links open in their own apps.
  A link to an app or script asks first: Show in Finder, Open or Cancel.
- YAML front matter is shown as a dim block. Scripts in documents never run (CSP).

Keys: ⌘N new, ⌘O open, ⌘E edit, ⇧⌘E external editor, ⌘F / ⌘G find, ⌘= / ⌘- / ⌘0 zoom, ⌘R reload, ⇧⌘R show in Finder, ⌘P print.
View › Appearance overrides the system setting.

Requirements: macOS 14 or later, on Apple silicon (the build is arm64 only).

## Build & install
    ./build.sh            # builds build/Vivarium.app
    ./build.sh --install  # builds, replaces /Applications/Vivarium.app, opens it

Building needs the Xcode command line tools. To make Vivarium the default app for Markdown,
select any .md file in Finder, choose File › Get Info (⌘I), pick Vivarium under Open with,
then click Change All….

## Files
- `main.swift` — the app (documents and saving, the editor pane, file watching, menus)
- `web/` — the page: `reader.html`, `reader.js` (Markdown → HTML), `reader.css`, and `vendor/`
  (marked 18.0.14, KaTeX 0.18.9, highlight.js 11.12.0, with their licences)
- `make-icon.swift` — draws `AppIcon.icns`; run once with `swift make-icon.swift`
