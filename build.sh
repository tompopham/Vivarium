#!/bin/zsh
# Builds build/Vivarium.app. With --install, replaces /Applications/Vivarium.app and opens it.
set -euo pipefail
cd "${0:A:h}"

app=build/Vivarium.app
rm -rf build
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
swiftc -O -target arm64-apple-macosx14.0 main.swift -o "$app/Contents/MacOS/Vivarium"
cp Info.plist "$app/Contents/Info.plist"
cp AppIcon.icns "$app/Contents/Resources/"
cp -R web "$app/Contents/Resources/web"
codesign --force --sign - "$app"

if [[ ${1:-} == --install ]]; then
  osascript -e 'quit app "Vivarium"' 2>/dev/null || true
  while pgrep -x Vivarium >/dev/null; do sleep 0.2; done
  rm -rf /Applications/Vivarium.app
  ditto "$app" /Applications/Vivarium.app
  # Re-register so Finder's "Open With" sees the document types.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Vivarium.app
  open /Applications/Vivarium.app
fi
