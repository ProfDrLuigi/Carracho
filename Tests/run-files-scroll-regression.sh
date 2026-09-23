#!/bin/bash
set -euo pipefail
# First build the Carracho Debug scheme, then pass its DerivedData directory here.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${1:?Usage: $0 /path/to/DerivedData (after building the Carracho Debug scheme)}"
ARCH="$(uname -m)"
PRODUCTS="$BUILD/Build/Products/Debug"
OBJECTS="$BUILD/Build/Intermediates.noindex/Carracho.build/Debug/Carracho.build/Objects-normal/$ARCH"
TEST_DIR="$(mktemp -d /tmp/carracho-scroll-regression.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
TEST_APP="$TEST_DIR/FilesScrollRegression.app"
mkdir -p "$TEST_APP/Contents/MacOS"
cat > "$TEST_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.carracho.FilesScrollRegression</string>
<key>CFBundleExecutable</key><string>FilesScrollRegression</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
# Link the actual client objects, replacing only the application's @main entry point.
awk '!/\/AppDelegate.o$/' "$OBJECTS/Carracho.LinkFileList" > "$TEST_DIR/objects"
xcrun swiftc -module-cache-path "$TEST_DIR/module-cache" \
    -I "$PRODUCTS" -F "$PRODUCTS" \
    "$ROOT/Tests/FilesScrollRegression.swift" \
    -Xlinker -filelist -Xlinker "$TEST_DIR/objects" \
    -Xlinker -rpath -Xlinker "$PRODUCTS" \
    -o "$TEST_APP/Contents/MacOS/FilesScrollRegression"
"$TEST_APP/Contents/MacOS/FilesScrollRegression"
