#!/usr/bin/env bash
# fm-install-treehouse.sh - install CI's pinned, verified Treehouse build.
#
# Used only by the required real-Herdr CI lane for E2E scripts that genuinely
# need treehouse (spawn worktree acquisition). Same pin/checksum discipline as
# fm-install-herdr.sh: official release URL, exact asset, SHA-256, bounded
# download, post-install version check. Never a floating package-manager latest.
#
# Usage:
#   fm-install-treehouse.sh <destination-directory>
#
# Pins Treehouse v2.0.1, the version exercised by the local real-Herdr suite.
#
# Platforms: linux and darwin (amd64, arm64) tarballs, plus Windows under Git
# Bash, MSYS or Cygwin (x86_64 and arm64 zips). Windows zips are extracted with
# Windows' own System32 tar.exe, because GNU tar cannot open zips, and install
# `treehouse.exe` into the destination.
set -eu

FM_TREEHOUSE_CI_VERSION=2.0.1
FM_TREEHOUSE_CI_TAG="v${FM_TREEHOUSE_CI_VERSION}"
# Bounded download ceiling (bytes). Official 2.0.1 archives are under 8 MiB.
FM_TREEHOUSE_CI_MAX_BYTES=15000000
FM_TREEHOUSE_CI_REPO=kunchenguid/treehouse

die() {
  printf 'fm-install-treehouse.sh: %s\n' "$*" >&2
  exit 1
}

DESTINATION=${1:?usage: fm-install-treehouse.sh <destination-directory>}

os=$(uname -s)
arch=$(uname -m)
case "${os}-${arch}" in
  Linux-x86_64)
    ARCHIVE=treehouse-v${FM_TREEHOUSE_CI_VERSION}-linux-amd64.tar.gz
    SHA256=1d5a32751ab921670103fd201ddb2b91b47338cb13976f45642b827cf8976af2
    ;;
  Linux-aarch64|Linux-arm64)
    ARCHIVE=treehouse-v${FM_TREEHOUSE_CI_VERSION}-linux-arm64.tar.gz
    SHA256=eaccc9c5b98125df8bd77425598eeecee66cb0371db4eb1cf75f0d813c18fab9
    ;;
  Darwin-arm64)
    ARCHIVE=treehouse-v${FM_TREEHOUSE_CI_VERSION}-darwin-arm64.tar.gz
    SHA256=7ee5078f3d1f33c01196548797fce65408e459d53530b77d4ba56e074fa1c1a2
    ;;
  Darwin-x86_64)
    ARCHIVE=treehouse-v${FM_TREEHOUSE_CI_VERSION}-darwin-amd64.tar.gz
    SHA256=1cf44580a5837f995e1d3bb74f4fbd3112b642acd20406087d9735a8106112fd
    ;;
  MINGW*-x86_64|MSYS*-x86_64|CYGWIN*-x86_64)
    ARCHIVE=treehouse-v${FM_TREEHOUSE_CI_VERSION}-windows-amd64.zip
    SHA256=d4c7bebc876b6dc1f9cf2f2b934803234d4f2f6e1c1c314505db85e64f5100bc
    ;;
  MINGW*-aarch64|MINGW*-arm64|MSYS*-aarch64|MSYS*-arm64|CYGWIN*-aarch64|CYGWIN*-arm64)
    ARCHIVE=treehouse-v${FM_TREEHOUSE_CI_VERSION}-windows-arm64.zip
    SHA256=4cb39138565822c26f694a5594787b770296061247cc6f3a3b6852d7c4212381
    ;;
  *)
    die "unsupported platform ${os}-${arch}; official Treehouse assets are linux/darwin amd64 and arm64"
    ;;
esac

URL="https://github.com/${FM_TREEHOUSE_CI_REPO}/releases/download/${FM_TREEHOUSE_CI_TAG}/${ARCHIVE}"
TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fm-treehouse.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

printf 'fm-install-treehouse.sh: downloading %s from %s\n' "$ARCHIVE" "$URL" >&2
curl -fsSL --max-filesize "$FM_TREEHOUSE_CI_MAX_BYTES" "$URL" -o "$TMP/$ARCHIVE" \
  || die "download failed for $URL (bounded at $FM_TREEHOUSE_CI_MAX_BYTES bytes)"

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(sha256sum "$TMP/$ARCHIVE" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(shasum -a 256 "$TMP/$ARCHIVE" | awk '{print $1}')
else
  die "need sha256sum or shasum to verify the Treehouse archive"
fi

[ "$ACTUAL_SHA256" = "$SHA256" ] || die "checksum mismatch for $ARCHIVE (expected $SHA256, got $ACTUAL_SHA256)"

case "$ARCHIVE" in
  *.zip)
    WIN_TAR="${SYSTEMROOT:-${WINDIR:-C:\Windows}}/System32/tar.exe"
    [ -x "$WIN_TAR" ] || die "need Windows tar.exe at $WIN_TAR to extract $ARCHIVE"
    "$WIN_TAR" -xf "$(cygpath -w "$TMP/$ARCHIVE")" -C "$(cygpath -w "$TMP")"       || die "could not extract $ARCHIVE"
    [ -f "$TMP/treehouse.exe" ] || die "archive $ARCHIVE did not contain treehouse.exe"
    mkdir -p "$DESTINATION"
    install -m 0755 "$TMP/treehouse.exe" "$DESTINATION/treehouse.exe"
    installed_version=$("$DESTINATION/treehouse" --version 2>/dev/null | tr -d '[:space:]')
    [ "$installed_version" = "v${FM_TREEHOUSE_CI_VERSION}" ]       || die "installed treehouse version is '${installed_version:-<empty>}', expected exact pin v${FM_TREEHOUSE_CI_VERSION}"
    printf 'fm-install-treehouse.sh: installed treehouse %s to %s
'       "$installed_version" "$DESTINATION/treehouse" >&2
    "$DESTINATION/treehouse" --version
    exit 0
    ;;
esac
tar -xzf "$TMP/$ARCHIVE" -C "$TMP"
# Archive layout: a single `treehouse` binary at the archive root (verified for v2.0.1).
if [ -f "$TMP/treehouse" ]; then
  BIN="$TMP/treehouse"
elif [ -f "$TMP/treehouse-v${FM_TREEHOUSE_CI_VERSION}/treehouse" ]; then
  BIN="$TMP/treehouse-v${FM_TREEHOUSE_CI_VERSION}/treehouse"
else
  BIN=$(find "$TMP" -type f -name treehouse | head -n 1)
  [ -n "$BIN" ] || die "archive $ARCHIVE did not contain a treehouse binary"
fi

mkdir -p "$DESTINATION"
install -m 0755 "$BIN" "$DESTINATION/treehouse"

installed_version=$("$DESTINATION/treehouse" --version 2>/dev/null | tr -d '[:space:]')
# treehouse prints "v2.0.1" (leading v) on --version.
case "$installed_version" in
  "v${FM_TREEHOUSE_CI_VERSION}"|"${FM_TREEHOUSE_CI_VERSION}") ;;
  *)
    die "installed treehouse version is '${installed_version:-<empty>}', expected exact pin v${FM_TREEHOUSE_CI_VERSION}"
    ;;
esac

printf 'fm-install-treehouse.sh: installed treehouse %s to %s\n' \
  "$installed_version" "$DESTINATION/treehouse" >&2
"$DESTINATION/treehouse" --version
