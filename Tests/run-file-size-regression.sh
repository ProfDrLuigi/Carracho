#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d /tmp/carracho-file-size-regression.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -module-cache-path "$test_dir/module-cache" -o "$test_dir/regression" \
    Carracho/LegacyProtocol/*.swift \
    Tests/FileSizeRegression.swift
"$test_dir/regression"
