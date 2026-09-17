#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
mkdir -p .build/linux
CC=${CC:-cc}
EXTRA_CFLAGS=${EXTRA_CFLAGS:-}
"$CC" -std=c11 -O2 -Wall -Wextra -Wpedantic $EXTRA_CFLAGS -pthread \
  TrackerLinux/main.c \
  -o .build/linux/carracho-tracker
printf 'built %s\n' "$ROOT/.build/linux/carracho-tracker"
