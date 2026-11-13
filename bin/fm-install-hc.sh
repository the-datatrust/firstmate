#!/usr/bin/env bash
# fm-install-hc.sh - install a pinned, verified Herdr Core (`hc`) build.
#
# Single owner of the exact herdr-core version, official release asset URLs,
# and SHA-256 pins used by the real-hc lab lane and by operators who want the
# verified build. Never installs a floating latest, and never runs upstream's
# install.sh or `hc update` - self-update is an operator-run step (the
# manifest pins below change only with a re-verified matrix).
#
# Usage:
#   fm-install-hc.sh <destination-directory>
#
# Pins herdr-core 0.1.14 (protocol generation 1), the suite-verified release.
# Selects the official releases.herdr.dev tarball for the host OS/arch,
# downloads with a bounded max size, verifies SHA-256 before install, extracts
# the `herdr-core` binary, then refuses to finish unless the installed binary
# reports `hc 0.1.14` exactly. The adapter (bin/backends/hc.sh) resolves
# `herdr-core` before the `hc` alias, so the asset name is what gets installed.
#
# Windows (Git Bash, MSYS or Cygwin, x86_64 only) pins herdr-core 0.1.21 through
# FM_HC_WINDOWS_PIN_VERSION, separate from the pin above; the Windows arm points
# FM_HC_PIN_VERSION at it, so the URL and the final version gate use it. The zip
# is extracted with Windows' own System32 tar.exe, because GNU tar cannot open
# zips. Both `herdr-core.exe` and its `conpty/` directory are installed, because
# the core fails to start without conpty/conpty.dll beside it.
set -eu

FM_HC_PIN_VERSION=0.1.14
# Windows-only pin, separate from the suite-verified pin above.
FM_HC_WINDOWS_PIN_VERSION=0.1.21
# Bounded download ceiling (bytes). The largest official 0.1.14 tarball is
# under 3 MiB.
FM_HC_MAX_BYTES=25000000
FM_HC_RELEASES=https://releases.herdr.dev/core

die() {
  printf 'fm-install-hc.sh: %s\n' "$*" >&2
  exit 1
}

DESTINATION=${1:?usage: fm-install-hc.sh <destination-directory>}

os=$(uname -s)
arch=$(uname -m)
case "${os}-${arch}" in
  Linux-x86_64)
    TARGET=linux-x86_64
    SHA256=e9dbabdead0ce0ce3de51b6f54cc9549efedbb41b2f8448b6932ab0d1442343e
    ;;
  Linux-aarch64|Linux-arm64)
    TARGET=linux-aarch64
    SHA256=19cef6a2e52f14c22c4b6f3fdaf1a462d2dafc78e8b03fabbfad5b063477a370
    ;;
  Darwin-arm64)
    TARGET=macos-aarch64
    SHA256=ca524329d2e0630219550055dcc71f42aafd85fba356e0d543d6f51244487970
    ;;
  Darwin-x86_64)
    TARGET=macos-x86_64
    SHA256=8e16ec43a17656f80e7d7f98292bf710c60c4aeff52941cca98fb24f37f35028
    ;;
  MINGW*-x86_64|MSYS*-x86_64|CYGWIN*-x86_64)
    TARGET=windows-x86_64
    SHA256=a8984634c35b58ba82d0aec078d5a5e6004da01d5a25b3daf822ab5e31c7312b
    FM_HC_PIN_VERSION=$FM_HC_WINDOWS_PIN_VERSION
    ASSET_EXT=zip
    ;;
  *)
    die "unsupported platform ${os}-${arch}; official herdr-core assets are linux/macos x86_64 and aarch64"
    ;;
esac

ASSET="herdr-core-${TARGET}.${ASSET_EXT:-tar.gz}"
URL="${FM_HC_RELEASES}/${FM_HC_PIN_VERSION}/${ASSET}"
TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fm-hc-install.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

printf 'fm-install-hc.sh: downloading %s from %s\n' "$ASSET" "$URL" >&2
# --fail: HTTP errors; --location: follow redirects; --max-filesize: bound.
curl -fsSL --max-filesize "$FM_HC_MAX_BYTES" "$URL" -o "$TMP/$ASSET" \
  || die "download failed for $URL (bounded at $FM_HC_MAX_BYTES bytes)"

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(sha256sum "$TMP/$ASSET" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(shasum -a 256 "$TMP/$ASSET" | awk '{print $1}')
else
  die "need sha256sum or shasum to verify the herdr-core asset"
fi

[ "$ACTUAL_SHA256" = "$SHA256" ] || die "checksum mismatch for $ASSET (expected $SHA256, got $ACTUAL_SHA256)"

if [ "${ASSET_EXT:-}" = zip ]; then
  WIN_TAR="${SYSTEMROOT:-${WINDIR:-C:\Windows}}/System32/tar.exe"
  [ -x "$WIN_TAR" ] || die "need Windows tar.exe at $WIN_TAR to extract $ASSET"
  "$WIN_TAR" -xf "$(cygpath -w "$TMP/$ASSET")" -C "$(cygpath -w "$TMP")" || die "could not extract $ASSET"
  [ -f "$TMP/herdr-core.exe" ] || die "$ASSET did not contain a herdr-core.exe binary"
  [ -f "$TMP/conpty/conpty.dll" ] || die "$ASSET did not contain conpty/conpty.dll"
  mkdir -p "$DESTINATION"
  install -m 0755 "$TMP/herdr-core.exe" "$DESTINATION/herdr-core.exe"
  rm -rf "$DESTINATION/conpty"
  cp -R "$TMP/conpty" "$DESTINATION/conpty"
  installed_version=$("$DESTINATION/herdr-core" --version 2>/dev/null | awk '{print $2; exit}')
  [ "$installed_version" = "$FM_HC_PIN_VERSION" ]     || die "installed herdr-core reports version '$installed_version', expected $FM_HC_PIN_VERSION"
  printf 'fm-install-hc.sh: installed herdr-core %s (protocol generation 1) to %s/herdr-core
'     "$installed_version" "$DESTINATION" >&2
  exit 0
fi

tar -xzf "$TMP/$ASSET" -C "$TMP" || die "could not extract $ASSET"
[ -f "$TMP/herdr-core" ] || die "$ASSET did not contain a herdr-core binary"

mkdir -p "$DESTINATION"
install -m 0755 "$TMP/herdr-core" "$DESTINATION/herdr-core"

# Post-install version and self-identity gates (no floating latest). The
# binary self-identifies as `hc x.y.z`; anything else is not Herdr Core.
installed_version=$("$DESTINATION/herdr-core" --version 2>/dev/null | awk '{print $2; exit}')
[ "$installed_version" = "$FM_HC_PIN_VERSION" ] \
  || die "installed herdr-core reports version '$installed_version', expected $FM_HC_PIN_VERSION"
printf 'fm-install-hc.sh: installed herdr-core %s (protocol generation 1) to %s/herdr-core\n' \
  "$installed_version" "$DESTINATION" >&2
