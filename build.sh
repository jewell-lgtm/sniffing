#!/bin/sh
# Build sniffing and install it to ~/Applications/sniffing.app.
set -eu
cd "$(dirname "$0")"
swift build -c release
app=build/sniffing.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/sniffing "$app/Contents/MacOS/sniffing"
cp Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
mkdir -p ~/Applications
rm -rf ~/Applications/sniffing.app
cp -R "$app" ~/Applications/sniffing.app
echo "installed ~/Applications/sniffing.app"
