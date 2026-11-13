#!/usr/bin/env bash
set -euo pipefail
[[ $(uname -s) == Darwin ]] || { echo 'This installer requires macOS.' >&2; exit 1; }
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
command -v swiftc >/dev/null || { echo 'Install Apple Command Line Tools: xcode-select --install' >&2; exit 1; }
if ! command -v adb >/dev/null && [[ ! -x /opt/local/bin/adb && ! -x /opt/homebrew/bin/adb && ! -x /usr/local/bin/adb && ! -x $HOME/Library/Android/sdk/platform-tools/adb ]]; then
    echo 'Install Android platform-tools with MacPorts or Homebrew first.' >&2
    exit 1
fi
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT
mkdir -p "$build/Send to BOOX.app/Contents/MacOS"
swiftc -parse-as-library -O -module-cache-path "${BOOX_SWIFT_MODULE_CACHE:-$build/cache}" "$source_dir/macos/SendToBoox.swift" -o "$build/Send to BOOX.app/Contents/MacOS/SendToBoox"
cp "$source_dir/macos/Info.plist" "$build/Send to BOOX.app/Contents/Info.plist"
codesign --force --sign - "$build/Send to BOOX.app"
mkdir -p "$HOME/Applications"
ditto "$build/Send to BOOX.app" "$HOME/Applications/Send to BOOX.app"
echo "Installed $HOME/Applications/Send to BOOX.app"
echo 'Open the app, or drag PDFs onto it in Finder or the Dock.'
