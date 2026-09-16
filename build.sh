#!/bin/sh
# Build the CLI, prove it with the test suite, then bundle the menu bar app.
# A red test stops the build before anything is installed.
set -eu
cd "$(dirname "$0")"

echo "==> 1/4 build"
swift build -c release

echo "==> 2/4 test"
swift build --build-tests
swift test --skip-build

echo "==> 3/4 bundle"
app=build/sniffing.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/sniffing "$app/Contents/MacOS/sniffing"
cp Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"

echo "==> 4/4 install"
mkdir -p ~/Applications ~/.local/bin
rm -rf ~/Applications/sniffing.app
cp -R "$app" ~/Applications/sniffing.app
ln -sf ~/Applications/sniffing.app/Contents/MacOS/sniffing ~/.local/bin/sniffing
echo "installed ~/Applications/sniffing.app and ~/.local/bin/sniffing"
