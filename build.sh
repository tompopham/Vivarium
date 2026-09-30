#!/bin/zsh
# Builds build/Reader.app. With --install, replaces /Applications/Reader.app and opens it.
set -euo pipefail
cd "${0:A:h}"

app=build/Reader.app
rm -rf build
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
swiftc -O -target arm64-apple-macosx14.0 main.swift -o "$app/Contents/MacOS/Reader"
cp Info.plist "$app/Contents/Info.plist"
cp AppIcon.icns "$app/Contents/Resources/"
cp -R web "$app/Contents/Resources/web"
codesign --force --sign - "$app"

if [[ ${1:-} == --install ]]; then
  osascript -e 'quit app "Reader"' 2>/dev/null || true
  while pgrep -x Reader >/dev/null; do sleep 0.2; done
  rm -rf /Applications/Reader.app
  ditto "$app" /Applications/Reader.app
  # Re-register so Finder's "Open With" sees the document types.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Reader.app
  open /Applications/Reader.app
fi
