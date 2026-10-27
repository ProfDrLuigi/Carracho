#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${1:?Usage: $0 /path/to/DerivedData }"
ARCH="$(uname -m)"
PRODUCTS="$BUILD/Build/Products/Debug"
OBJECTS="$BUILD/Build/Intermediates.noindex/Carracho.build/Debug/Carracho.build/Objects-normal/$ARCH"
TEST_DIR="$(mktemp -d /tmp/carracho-media-attachments.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
TEST_APP="$TEST_DIR/MediaAttachmentRegression.app"
mkdir -p "$TEST_APP/Contents/MacOS"
cat > "$TEST_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.carracho.MediaAttachmentRegression</string>
<key>CFBundleExecutable</key><string>MediaAttachmentRegression</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
awk '!/\/AppDelegate.o$/' "$OBJECTS/Carracho.LinkFileList" > "$TEST_DIR/objects"
xcrun swiftc -default-isolation MainActor -module-cache-path "$TEST_DIR/module-cache" \
    -I "$PRODUCTS" -F "$PRODUCTS" \
    "$ROOT/Tests/MediaAttachmentRegression.swift" \
    -Xlinker -filelist -Xlinker "$TEST_DIR/objects" \
    -Xlinker -rpath -Xlinker "$PRODUCTS" \
    -o "$TEST_APP/Contents/MacOS/MediaAttachmentRegression"
mkdir -p "$TEST_DIR/home"
CFFIXED_USER_HOME="$TEST_DIR/home" "$TEST_APP/Contents/MacOS/MediaAttachmentRegression" "$TEST_DIR" \
    --avatar-store-directory="$TEST_DIR/avatars"
