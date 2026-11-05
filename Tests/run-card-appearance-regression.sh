#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d /tmp/carracho-card-appearance.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -module-cache-path "$test_dir/module-cache" -o "$test_dir/regression" \
    Carracho/CarrachoTheme.swift Carracho/Gui/Localization.swift Tests/CardAppearanceRegression.swift
"$test_dir/regression"
