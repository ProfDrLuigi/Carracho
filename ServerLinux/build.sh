#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
mkdir -p .build/linux/etc .build/linux/db
CC=${CC:-cc}
EXTRA_CFLAGS=${EXTRA_CFLAGS:-}
CFLAGS="$(pkg-config --cflags openssl json-c sqlite3 libcurl libxml-2.0)"
LIBS="$(pkg-config --libs openssl json-c sqlite3 libcurl libxml-2.0)"
WEBADMIN_CFLAGS="-IServerLinux/Webinterface/linux"
case "$(uname -s)" in Darwin) ICONV_LIBS="-liconv" ;; *) ICONV_LIBS="" ;; esac
# OpenSSL 3 keeps the low-level Blowfish primitive for compatibility; the wire
# protocol requires that exact primitive and its historical key schedule.
"$CC" -std=c11 -O2 -Wall -Wextra -Wpedantic -Wmisleading-indentation $EXTRA_CFLAGS -Wno-deprecated-declarations -pthread $CFLAGS $WEBADMIN_CFLAGS \
  ServerLinux/main.c ServerLinux/server_runtime.c ServerLinux/bot_rss.c ServerLinux/bot_file_watch.c ServerLinux/server_state.c ServerLinux/sqlite_state.c ServerLinux/carracho_protocol.c ServerLinux/file_metadata.c ServerLinux/file_search_index.c ServerLinux/news_store.c ServerLinux/flat_news_store.c ServerLinux/media_store.c ServerLinux/Webinterface/linux/carracho_web_admin_service.c \
  $LIBS $ICONV_LIBS -o .build/linux/carracho-server
if [ ! -e .build/linux/etc/carracho-server.json ]; then
  cp ServerLinux/etc/carracho-server.json .build/linux/etc/carracho-server.json
fi
if [ ! -e .build/linux/etc/carracho-bot.json ]; then
  cp ServerLinux/etc/carracho-bot.json .build/linux/etc/carracho-bot.json
fi
printf 'built %s\n' "$ROOT/.build/linux/carracho-server"
printf 'config %s\n' "$ROOT/.build/linux/etc/carracho-server.json"
printf 'bot config %s\n' "$ROOT/.build/linux/etc/carracho-bot.json"
