#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$(mktemp /tmp/carracho-bookmark-reorder.XXXXXX)"
trap 'rm -f "$OUTPUT"' EXIT
xcrun swiftc -o "$OUTPUT" \
    "$ROOT/Carracho/Client/BookmarkReorderPolicy.swift" \
    "$ROOT/Tests/BookmarkReorderRegression.swift" \
    -framework AppKit
"$OUTPUT"
