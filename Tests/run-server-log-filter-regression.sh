#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output="$(mktemp -t carracho-serverlog-filter)"
trap 'rm -f "$output"' EXIT
xcrun swiftc -o "$output" Carracho/Gui/ServerLogFilter.swift Tests/ServerLogFilterRegression.swift
"$output"
