#!/usr/bin/env bash
# fm-install-windows.test.sh - the pinned installers and bootstrap install hints
# pick Windows assets and commands under a Git Bash `uname`, and leave Linux
# untouched. A PATH `uname` reports the platform under test, a PATH `curl` stub
# records the requested URL and refuses the download, and PATH `winget` and
# `powershell.exe` stubs record what the install hints run, so nothing is
# fetched or installed.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-install-windows)
FAKEBIN=$(fm_fakebin "$TMP")

cat > "$FAKEBIN/uname" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -s) printf '%s\n' "$FM_TEST_UNAME_S" ;;
  -m) printf '%s\n' "$FM_TEST_UNAME_M" ;;
  *) printf '%s\n' "$FM_TEST_UNAME_S" ;;
esac
SH
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in https://*) printf '%s\n' "$arg" > "$FM_CURL_URL_LOG" ;; esac
done
exit 22
SH
for tool in winget powershell.exe; do
  cat > "$FAKEBIN/$tool" <<'SH'
#!/usr/bin/env bash
printf '%s' "$(basename "$0")" >> "$FM_TEST_RUN_LOG"
for arg in "$@"; do printf '|%s' "$arg" >> "$FM_TEST_RUN_LOG"; done
printf '\n' >> "$FM_TEST_RUN_LOG"
SH
done
chmod +x "$FAKEBIN/uname" "$FAKEBIN/curl" "$FAKEBIN/winget" "$FAKEBIN/powershell.exe"

WIN_S=MINGW64_NT-10.0-26200

# requested_url <script> <uname -s> <uname -m>: run the installer into a scratch
# destination and print the URL it asked curl for.
requested_url() {
  rm -f "$TMP/url"
  FM_TEST_UNAME_S=$2 FM_TEST_UNAME_M=$3 FM_CURL_URL_LOG="$TMP/url" \
    PATH="$FAKEBIN:$PATH" RUNNER_TEMP="$TMP" \
    bash "$ROOT/bin/$1" "$TMP/dest" >/dev/null 2>"$TMP/err" || true
  cat "$TMP/url" 2>/dev/null || true
}

test_hc_windows_asset() {
  local url
  url=$(requested_url fm-install-hc.sh "$WIN_S" x86_64)
  [ "$url" = "https://releases.herdr.dev/core/0.1.21/herdr-core-windows-x86_64.zip" ] \
    || fail "hc on Windows requested '$url': $(cat "$TMP/err")"
  pass "hc installer: Git Bash x86_64 downloads the pinned Windows zip"
}

test_hc_linux_asset_unchanged() {
  local url
  url=$(requested_url fm-install-hc.sh Linux x86_64)
  [ "$url" = "https://releases.herdr.dev/core/0.1.14/herdr-core-linux-x86_64.tar.gz" ] \
    || fail "hc on Linux requested '$url'"
  pass "hc installer: Linux still downloads the 0.1.14 tarball"
}

test_hc_windows_arm64_refused() {
  local code=0
  FM_TEST_UNAME_S=$WIN_S FM_TEST_UNAME_M=aarch64 FM_CURL_URL_LOG="$TMP/url" \
    PATH="$FAKEBIN:$PATH" RUNNER_TEMP="$TMP" \
    bash "$ROOT/bin/fm-install-hc.sh" "$TMP/dest" 2>"$TMP/err" || code=$?
  [ "$code" -ne 0 ] || fail "hc installer accepted Windows arm64"
  grep -q 'unsupported platform' "$TMP/err" || fail "no unsupported-platform message: $(cat "$TMP/err")"
  pass "hc installer: Windows arm64 is refused"
}

test_treehouse_windows_assets() {
  local url
  url=$(requested_url fm-install-treehouse.sh "$WIN_S" x86_64)
  [ "$url" = "https://github.com/kunchenguid/treehouse/releases/download/v2.0.1/treehouse-v2.0.1-windows-amd64.zip" ] \
    || fail "treehouse on Windows x86_64 requested '$url'"
  url=$(requested_url fm-install-treehouse.sh "$WIN_S" aarch64)
  [ "$url" = "https://github.com/kunchenguid/treehouse/releases/download/v2.0.1/treehouse-v2.0.1-windows-arm64.zip" ] \
    || fail "treehouse on Windows arm64 requested '$url'"
  pass "treehouse installer: Git Bash downloads the pinned Windows zip per architecture"
}

test_treehouse_linux_asset_unchanged() {
  local url
  url=$(requested_url fm-install-treehouse.sh Linux x86_64)
  [ "$url" = "https://github.com/kunchenguid/treehouse/releases/download/v2.0.1/treehouse-v2.0.1-linux-amd64.tar.gz" ] \
    || fail "treehouse on Linux requested '$url'"
  pass "treehouse installer: Linux still downloads the tarball"
}

# install_run <uname -s> <tool>: run `fm-bootstrap.sh install <tool>` with the
# winget and powershell.exe stubs on PATH; print the echoed line, then the
# stubbed invocations (argv joined by `|`).
install_run() {
  : > "$TMP/run.log"
  FM_TEST_UNAME_S=$1 FM_TEST_UNAME_M=x86_64 FM_TEST_RUN_LOG="$TMP/run.log" \
    PATH="$FAKEBIN:$PATH" bash "$ROOT/bin/fm-bootstrap.sh" install "$2" 2>&1 || true
  cat "$TMP/run.log"
}

test_bootstrap_windows_winget_hints() {
  local tool id out pair
  for pair in node:OpenJS.NodeJS.LTS git:Git.Git gh:GitHub.cli jq:jqlang.jq; do
    tool=${pair%%:*}
    id=${pair#*:}
    out=$(install_run "$WIN_S" "$tool")
    case "$out" in
      "installing $tool: winget install -e --id $id"*"winget|install|-e|--id|$id") ;;
      *) fail "bootstrap install $tool on Windows ran: $out" ;;
    esac
  done
  pass "bootstrap install: Windows node, git, gh and jq run winget with their package ids"
}

test_bootstrap_windows_powershell_hints() {
  local out
  out=$(install_run "$WIN_S" treehouse)
  case "$out" in
    *"powershell.exe|-NoProfile|-ExecutionPolicy|Bypass|-Command|irm https://kunchenguid.github.io/treehouse/install.ps1 | iex") ;;
    *) fail "bootstrap install treehouse on Windows ran: $out" ;;
  esac
  out=$(install_run "$WIN_S" no-mistakes)
  case "$out" in
    *"powershell.exe|-NoProfile|-ExecutionPolicy|Bypass|-Command|irm https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.ps1 | iex") ;;
    *) fail "bootstrap install no-mistakes on Windows ran: $out" ;;
  esac
  pass "bootstrap install: Windows treehouse and no-mistakes pass the whole irm | iex string to PowerShell"
}

test_bootstrap_linux_hint_unchanged() {
  local out
  out=$(install_run Linux treehouse)
  case "$out" in
    "installing treehouse: curl -fsSL https://kunchenguid.github.io/treehouse/install.sh | sh"*) ;;
    *) fail "bootstrap install treehouse on Linux printed: $out" ;;
  esac
  case "$out" in *powershell*|*winget*) fail "Linux hint mentions Windows tooling: $out" ;; esac
  pass "bootstrap install: Linux treehouse hint is the existing shell installer"
}

fm_test_run \
  test_hc_windows_asset \
  test_hc_linux_asset_unchanged \
  test_hc_windows_arm64_refused \
  test_treehouse_windows_assets \
  test_treehouse_linux_asset_unchanged \
  test_bootstrap_windows_winget_hints \
  test_bootstrap_windows_powershell_hints \
  test_bootstrap_linux_hint_unchanged
