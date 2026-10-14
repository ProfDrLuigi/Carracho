#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Optionally pass a built native server executable as the second argument.
BUILD="${1:?Usage: $0 /path/to/DerivedData [native-server-binary]}"
ARCH="$(uname -m)"
PRODUCTS="$BUILD/Build/Products/Debug"
OBJECTS="$BUILD/Build/Intermediates.noindex/Carracho.build/Debug/Carracho.build/Objects-normal/$ARCH"
TEST_DIR="$(mktemp -d /tmp/carracho-size-integration.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
TEST_APP="$TEST_DIR/FileSizeRegression.app"
mkdir -p "$TEST_APP/Contents/MacOS"
cat > "$TEST_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.carracho.FileSizeRegression</string>
<key>CFBundleExecutable</key><string>FileSizeRegression</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
awk '!/\/AppDelegate.o$/' "$OBJECTS/Carracho.LinkFileList" > "$TEST_DIR/objects"
xcrun swiftc -module-cache-path "$TEST_DIR/module-cache" \
    -I "$PRODUCTS" -F "$PRODUCTS" \
    "$ROOT/Tests/FileSizeIntegrationRegression.swift" \
    -Xlinker -filelist -Xlinker "$TEST_DIR/objects" \
    -Xlinker -rpath -Xlinker "$PRODUCTS" \
    -o "$TEST_APP/Contents/MacOS/FileSizeRegression"
"$TEST_APP/Contents/MacOS/FileSizeRegression" "${@:2}"
