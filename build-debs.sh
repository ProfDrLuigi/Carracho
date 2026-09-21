#!/usr/bin/env bash
set -euo pipefail
umask 022

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

MODE="all"
SKIP_WEBADMIN=0
VERSION_OVERRIDE=""

usage() {
    cat <<'EOF'
Usage: ./build-debs.sh [all|server|tracker] [--version VERSION] [--skip-webadmin]

Builds native Debian packages into .build/deb/.

Examples:
  ./build-debs.sh
  ./build-debs.sh server
  ./build-debs.sh tracker
  ./build-debs.sh all --version 1.0.5
  ./build-debs.sh server --skip-webadmin

Environment:
  EXTRA_CFLAGS      Extra C compiler flags. Defaults to -Werror.
  DEB_COMPRESSION   Debian archive compression. Defaults to gzip for old dpkg compatibility.
EOF
}

while (($#)); do
    case "$1" in
        all|server|tracker)
            MODE="$1"
            shift
            ;;
        --version)
            [[ $# -ge 2 ]] || { echo "error: --version requires a value" >&2; exit 2; }
            VERSION_OVERRIDE="$2"
            shift 2
            ;;
        --skip-webadmin)
            SKIP_WEBADMIN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[[ "$(uname -s)" == "Linux" ]] || {
    echo "error: Debian packages must be built on Linux." >&2
    echo "       Run this script on Debian/Ubuntu or in the Linux build VM." >&2
    exit 1
}

for tool in dpkg dpkg-deb dpkg-shlibdeps pkg-config install awk sed grep mktemp objdump sort; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "error: required build tool is missing: $tool" >&2
        exit 1
    }
done

ARCH="$(dpkg --print-architecture)"
EXTRA_CFLAGS="${EXTRA_CFLAGS:--Werror}"
DEB_COMPRESSION="${DEB_COMPRESSION:-gzip}"
export EXTRA_CFLAGS

if [[ -n "$VERSION_OVERRIDE" ]]; then
    VERSION="$VERSION_OVERRIDE"
else
    VERSION="$(
        sed -n 's/.*Carracho Server \([0-9][0-9A-Za-z.+:~_-]*\).*/\1/p' \
            ServerLinux/server_runtime.c | head -n 1
    )"
fi
[[ -n "$VERSION" ]] || {
    echo "error: could not determine package version from ServerLinux/server_runtime.c" >&2
    exit 1
}
if ! dpkg --validate-version "$VERSION" >/dev/null 2>&1; then
    echo "error: invalid Debian package version: $VERSION" >&2
    exit 1
fi

OUT="$ROOT/.build/deb"
STAGE_ROOT="$OUT/stage"
mkdir -p "$OUT"
rm -rf "$STAGE_ROOT"
mkdir -p "$STAGE_ROOT"

binary_glibc_min() {
    local binary="$1"
    objdump -T "$binary" 2>/dev/null \
        | grep -o 'GLIBC_[0-9.]*' \
        | sed 's/^GLIBC_//' \
        | sort -Vu \
        | tail -n 1
}

package_glibc_min() {
    local min="" binary version
    for binary in "$@"; do
        [[ -x "$binary" ]] || continue
        version="$(binary_glibc_min "$binary")"
        [[ -n "$version" ]] || continue
        if [[ -z "$min" ]] || dpkg --compare-versions "$version" gt "$min"; then
            min="$version"
        fi
    done
    [[ -n "$min" ]] || min="unknown"
    printf '%s' "$min"
}

runtime_depends() {
    local package="$1"
    shift
    local tmp output
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/debian"
    cat > "$tmp/debian/control" <<EOF
Source: $package
Section: net
Priority: optional
Maintainer: Carracho Project <noreply@carracho.invalid>
Standards-Version: 4.6.2

Package: $package
Architecture: any
Description: temporary shlib dependency scan
EOF

    local args=()
    local binary
    for binary in "$@"; do
        [[ -x "$binary" ]] || continue
        args+=("-e$binary")
    done
    if ((${#args[@]} == 0)); then
        rm -rf "$tmp"
        printf '%s' "libc6"
        return
    fi

    output="$(cd "$tmp" && dpkg-shlibdeps -O "${args[@]}" 2>/dev/null)"
    rm -rf "$tmp"
    output="${output#shlibs:Depends=}"
    printf '%s' "${output:-libc6}"
}

write_common_maintainer_scripts() {
    local stage="$1"
    local service="$2"

    cat > "$stage/DEBIAN/postrm" <<EOF
#!/bin/sh
set -e
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
fi
exit 0
EOF
    chmod 0755 "$stage/DEBIAN/postrm"

    cat > "$stage/DEBIAN/prerm" <<EOF
#!/bin/sh
set -e
if [ "\${1:-}" = "remove" ] && command -v systemctl >/dev/null 2>&1; then
    systemctl stop $service >/dev/null 2>&1 || true
    systemctl disable $service >/dev/null 2>&1 || true
fi
exit 0
EOF
    chmod 0755 "$stage/DEBIAN/prerm"
}

write_server_package() {
    echo "==> Building native Carracho Server"
    ./ServerLinux/build.sh

    local helper=""
    if ((SKIP_WEBADMIN == 0)); then
        echo "==> Building bundled WebAdmin helper"
        local helper_stage="$ROOT/.build/linux/libexec/carracho"
        ./ServerLinux/Webinterface/scripts/linux-build-phase.sh "$helper_stage"
        helper="$helper_stage/carracho-web-admin-helper"
        [[ -x "$helper" ]] || {
            echo "error: WebAdmin helper build did not produce $helper" >&2
            exit 1
        }
    fi

    local stage="$STAGE_ROOT/carracho-server"
    rm -rf "$stage"
    install -d -m 0755 \
        "$stage/DEBIAN" \
        "$stage/opt/carracho/etc" \
        "$stage/opt/carracho/db" \
        "$stage/opt/carracho/logs" \
        "$stage/opt/carracho/daemon" \
        "$stage/opt/carracho/Files" \
        "$stage/opt/carracho/Files-Legacy" \
        "$stage/lib/systemd/system" \
        "$stage/usr/share/doc/carracho-server"

    install -m 0755 .build/linux/carracho-server "$stage/opt/carracho/carracho-server"
    install -m 0600 ServerLinux/etc/carracho-server.json "$stage/opt/carracho/etc/carracho-server.json"
    install -m 0600 ServerLinux/etc/carracho-bot.json "$stage/opt/carracho/etc/carracho-bot.json"

    if [[ -n "$helper" ]]; then
        install -d -m 0755 "$stage/opt/carracho/libexec/carracho"
        install -m 0755 "$helper" "$stage/opt/carracho/libexec/carracho/carracho-web-admin-helper"
    fi

    cat > "$stage/lib/systemd/system/carracho.service" <<'EOF'
[Unit]
Description=Carracho Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=carracho
Group=carracho
WorkingDirectory=/opt/carracho
EnvironmentFile=-/opt/carracho/etc/carracho-server.env
ExecStart=/opt/carracho/carracho-server --config /opt/carracho/etc/carracho-server.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    cat > "$stage/usr/share/doc/carracho-server/README.Debian" <<'EOF'
Carracho Server for Debian
==========================

Runtime layout:
  /opt/carracho/carracho-server
  /opt/carracho/etc/
  /opt/carracho/db/
  /opt/carracho/logs/
  /opt/carracho/Files/
  /opt/carracho/Files-Legacy/

The package creates a system user named "carracho" and generates a persistent
HTTP Admin bearer token in /opt/carracho/etc/carracho-server.env when needed.

The service is intentionally not started automatically on first install.
Review the configuration and initial accounts, then start it with:

  systemctl enable --now carracho.service

Existing modified JSON configuration files are preserved by dpkg upgrades.
EOF

    cat > "$stage/DEBIAN/conffiles" <<'EOF'
/opt/carracho/etc/carracho-server.json
/opt/carracho/etc/carracho-bot.json
EOF

    local deps glibc_min package_version
    local binaries=("$stage/opt/carracho/carracho-server")
    [[ -n "$helper" ]] && binaries+=("$stage/opt/carracho/libexec/carracho/carracho-web-admin-helper")
    deps="$(runtime_depends carracho-server "${binaries[@]}")"
    glibc_min="$(package_glibc_min "${binaries[@]}")"
    package_version="${VERSION}+glibc${glibc_min}"
    dpkg --validate-version "$package_version" >/dev/null
    case ", $deps, " in
        *", adduser, "*) ;;
        *) deps="$deps, adduser" ;;
    esac

    cat > "$stage/DEBIAN/control" <<EOF
Package: carracho-server
Version: $package_version
Section: net
Priority: optional
Architecture: $ARCH
Maintainer: Carracho Project <noreply@carracho.invalid>
Depends: $deps
Description: Carracho community server
 Native headless Carracho server with chat, files, News, messaging,
 administration and Classic compatibility.
EOF

    cat > "$stage/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e

if ! getent group carracho >/dev/null 2>&1; then
    addgroup --system carracho >/dev/null
fi
if ! getent passwd carracho >/dev/null 2>&1; then
    adduser --system --ingroup carracho --home /opt/carracho \
        --no-create-home --shell /usr/sbin/nologin carracho >/dev/null
fi

install -d -o carracho -g carracho -m 0755 \
    /opt/carracho /opt/carracho/db /opt/carracho/logs /opt/carracho/daemon \
    /opt/carracho/Files /opt/carracho/Files-Legacy
install -d -o carracho -g carracho -m 0750 /opt/carracho/etc

for f in /opt/carracho/etc/carracho-server.json /opt/carracho/etc/carracho-bot.json; do
    if [ -f "$f" ]; then
        chown carracho:carracho "$f"
        chmod 0600 "$f"
    fi
done

ENV=/opt/carracho/etc/carracho-server.env
token=""
if [ -f "$ENV" ]; then
    token="$(sed -n 's/^CARRACHO_HTTP_ADMIN_TOKEN=//p' "$ENV" | head -n 1)"
fi
if [ "${#token}" -lt 24 ]; then
    umask 077
    token="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
    printf 'CARRACHO_HTTP_ADMIN_TOKEN=%s\n' "$token" > "$ENV"
fi
chown root:root "$ENV"
chmod 0600 "$ENV"

if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    if systemctl is-active --quiet carracho.service; then
        systemctl restart carracho.service
    fi
fi

exit 0
EOF
    chmod 0755 "$stage/DEBIAN/postinst"
    write_common_maintainer_scripts "$stage" "carracho.service"

    local deb="$OUT/carracho-server_${package_version}_${ARCH}.deb"
    find "$OUT" -maxdepth 1 -type f \
        \( -name "carracho-server_${VERSION}_${ARCH}.deb" -o \
           -name "carracho-server_${VERSION}+*_${ARCH}.deb" \) \
        -delete
    dpkg-deb -Z"$DEB_COMPRESSION" --root-owner-group --build "$stage" "$deb" >/dev/null
    echo "==> Built $deb (minimum GLIBC $glibc_min)"
}

write_tracker_package() {
    echo "==> Building native Carracho Tracker"
    ./TrackerLinux/build.sh

    local stage="$STAGE_ROOT/carracho-tracker"
    rm -rf "$stage"
    install -d -m 0755 \
        "$stage/DEBIAN" \
        "$stage/opt/carracho" \
        "$stage/lib/systemd/system" \
        "$stage/usr/share/doc/carracho-tracker"

    install -m 0755 .build/linux/carracho-tracker "$stage/opt/carracho/carracho-tracker"

    cat > "$stage/lib/systemd/system/carracho-tracker.service" <<'EOF'
[Unit]
Description=Carracho Tracker
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=carracho
Group=carracho
WorkingDirectory=/opt/carracho
ExecStart=/opt/carracho/carracho-tracker --port 6702
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    cat > "$stage/usr/share/doc/carracho-tracker/README.Debian" <<'EOF'
Carracho Tracker for Debian
===========================

The tracker listens on TCP port 6702 by default.

The service is intentionally not started automatically on first install.
Start it with:

  systemctl enable --now carracho-tracker.service
EOF

    local deps glibc_min package_version
    deps="$(runtime_depends carracho-tracker "$stage/opt/carracho/carracho-tracker")"
    glibc_min="$(package_glibc_min "$stage/opt/carracho/carracho-tracker")"
    package_version="${VERSION}+glibc${glibc_min}"
    dpkg --validate-version "$package_version" >/dev/null
    case ", $deps, " in
        *", adduser, "*) ;;
        *) deps="$deps, adduser" ;;
    esac

    cat > "$stage/DEBIAN/control" <<EOF
Package: carracho-tracker
Version: $package_version
Section: net
Priority: optional
Architecture: $ARCH
Maintainer: Carracho Project <noreply@carracho.invalid>
Depends: $deps
Description: Carracho server directory tracker
 Native Carracho tracker service for publishing and discovering Carracho servers.
EOF

    cat > "$stage/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e

if ! getent group carracho >/dev/null 2>&1; then
    addgroup --system carracho >/dev/null
fi
if ! getent passwd carracho >/dev/null 2>&1; then
    adduser --system --ingroup carracho --home /opt/carracho \
        --no-create-home --shell /usr/sbin/nologin carracho >/dev/null
fi
install -d -o carracho -g carracho -m 0755 /opt/carracho

if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    if systemctl is-active --quiet carracho-tracker.service; then
        systemctl restart carracho-tracker.service
    fi
fi

exit 0
EOF
    chmod 0755 "$stage/DEBIAN/postinst"
    write_common_maintainer_scripts "$stage" "carracho-tracker.service"

    local deb="$OUT/carracho-tracker_${package_version}_${ARCH}.deb"
    find "$OUT" -maxdepth 1 -type f \
        \( -name "carracho-tracker_${VERSION}_${ARCH}.deb" -o \
           -name "carracho-tracker_${VERSION}+*_${ARCH}.deb" \) \
        -delete
    dpkg-deb -Z"$DEB_COMPRESSION" --root-owner-group --build "$stage" "$deb" >/dev/null
    echo "==> Built $deb (minimum GLIBC $glibc_min)"
}

case "$MODE" in
    all)
        write_server_package
        write_tracker_package
        ;;
    server)
        write_server_package
        ;;
    tracker)
        write_tracker_package
        ;;
esac

echo
echo "Debian packages:"
find "$OUT" -maxdepth 1 -type f -name '*.deb' -print | sort
