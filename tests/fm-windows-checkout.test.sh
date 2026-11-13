#!/usr/bin/env bash
# fm-windows-checkout.test.sh - bin/fm-windows-checkout.sh and its bootstrap
# wiring. A PATH `uname` picks the platform, a PATH `cygpath` and `cmd` stand in
# for Windows' junction tooling (cmd makes a symlink for mklink /J and removes it
# for rmdir), and a throwaway clone made with core.symlinks=false holds the two
# tracked directory links as text files. One test runs the real mklink and skips
# off Windows.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-windows-checkout)
FAKEBIN=$(fm_fakebin "$TMP")
REAL_UNAME_S=$(uname -s)
# On a Windows host the stubs hand off to the real cygpath and cmd, because Git
# Bash's `ln -s` copies instead of linking; elsewhere they emulate them.
FM_TEST_REAL_CYGPATH=
FM_TEST_REAL_CMD=
case "$REAL_UNAME_S" in
  MINGW*|MSYS*|CYGWIN*)
    FM_TEST_REAL_CYGPATH=$(command -v cygpath)
    FM_TEST_REAL_CMD=$(command -v cmd)
    ;;
esac
export FM_TEST_REAL_CYGPATH FM_TEST_REAL_CMD

cat > "$FAKEBIN/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$FM_TEST_UNAME_S"
SH
cat > "$FAKEBIN/cygpath" <<'SH'
#!/usr/bin/env bash
[ -z "$FM_TEST_REAL_CYGPATH" ] || exec "$FM_TEST_REAL_CYGPATH" "$@"
printf '%s\n' "$2"
SH
cat > "$FAKEBIN/cmd" <<'SH'
#!/usr/bin/env bash
# cmd /c mklink /J <link> <target> | cmd /c rmdir <link>
[ "$1" = /c ] || exit 1
if [ -n "$FM_TEST_REAL_CMD" ]; then
  [ "$2 ${FM_TEST_MKLINK_FAIL:-}" = "mklink 1" ] || exec "$FM_TEST_REAL_CMD" "$@"
  exit 0
fi
case "$2" in
  mklink) [ "${FM_TEST_MKLINK_FAIL:-}" = 1 ] || ln -s "$5" "$4" ;;
  rmdir) rm "$3" ;;
esac
SH
chmod +x "$FAKEBIN/uname" "$FAKEBIN/cygpath" "$FAKEBIN/cmd"

# make_clone <name>: a clone whose tracked directory links are text files.
make_clone() {
  local origin="$TMP/$1-origin" clone="$TMP/$1" blob
  git init -q "$origin"
  mkdir -p "$origin/.agents/skills/a" "$origin/.claude/mods/calm"
  echo a > "$origin/.agents/skills/a/SKILL.md"
  echo c > "$origin/.claude/mods/calm/x"
  blob=$(printf '%s' ../.agents/skills | git -C "$origin" hash-object -w --stdin)
  git -C "$origin" update-index --add --cacheinfo "120000,$blob,.claude/skills"
  blob=$(printf '%s' ../../.claude/mods/calm | git -C "$origin" hash-object -w --stdin)
  git -C "$origin" update-index --add --cacheinfo "120000,$blob,.agents/skills/firstmate-calm"
  git -C "$origin" add .agents/skills/a .claude/mods
  git -C "$origin" -c user.name=t -c user.email=t@example.test commit -qm init
  git -c core.symlinks=false clone -q "$origin" "$clone"
  git -C "$clone" config core.symlinks false
  printf '%s\n' "$clone"
}

run() {  # <uname-s> <clone> <args...>
  local u=$1 clone=$2
  shift 2
  FM_TEST_UNAME_S=$u FM_WINCHECKOUT_ROOT=$clone PATH="$FAKEBIN:$PATH" \
    bash "$ROOT/bin/fm-windows-checkout.sh" "$@"
}

WIN_S=MINGW64_NT-10.0-26200

test_check_is_silent_off_windows() {
  local clone out
  clone=$(make_clone off)
  out=$(run Linux "$clone" check)
  [ -z "$out" ] || fail "check printed on Linux: $out"
  pass "windows-checkout: check is silent off Windows"
}

test_check_reports_broken_links_and_autocrlf() {
  local clone out
  clone=$(make_clone chk)
  out=$(run "$WIN_S" "$clone" check)
  [ "$(printf '%s\n' "$out" | grep -c '^WINDOWS_CHECKOUT: broken-link ')" = 2 ] || fail "expected two broken links: $out"
  case "$out" in *"broken-link .claude/skills "*"broken-link .agents/skills/firstmate-calm "*) ;; *) fail "wrong paths: $out" ;; esac
  case "$out" in *autocrlf*) fail "autocrlf warned while unset: $out" ;; esac
  git -C "$clone" config core.autocrlf true
  out=$(run "$WIN_S" "$clone" check)
  case "$out" in *"WINDOWS_CHECKOUT: autocrlf core.autocrlf=true"*) ;; *) fail "no autocrlf warning: $out" ;; esac
  pass "windows-checkout: check names each broken link and warns on autocrlf=true"
}

test_repair_then_check_status_add_and_idempotency() {
  local clone out ex
  clone=$(make_clone rep)
  run "$WIN_S" "$clone" repair || fail "repair failed"
  [ -d "$clone/.claude/skills/a" ] || fail "no link at .claude/skills"
  [ -d "$clone/.agents/skills/firstmate-calm" ] || fail "no link at firstmate-calm"
  out=$(run "$WIN_S" "$clone" check)
  [ -z "$out" ] || fail "check after repair printed: $out"
  [ -z "$(git -C "$clone" status --porcelain)" ] || fail "status not clean: $(git -C "$clone" status --porcelain)"
  git -C "$clone" add -A
  [ -z "$(git -C "$clone" diff --cached --name-only)" ] || fail "add -A staged: $(git -C "$clone" diff --cached --name-only)"
  ex=$(git -C "$clone" rev-parse --git-path info/exclude)
  run "$WIN_S" "$clone" repair || fail "second repair failed"
  [ "$(grep -c '^/.claude/skills$' "$clone/$ex")" = 1 ] || fail "exclude line duplicated"
  pass "windows-checkout: repair makes clean, unstageable links and is idempotent"
}

test_repair_refuses_user_data() {
  local clone
  clone=$(make_clone refuse)
  printf 'my notes\n' > "$clone/.claude/skills"
  if run "$WIN_S" "$clone" repair 2>"$TMP/err"; then fail "repair accepted a modified file"; fi
  [ "$(cat "$clone/.claude/skills")" = "my notes" ] || fail "user file changed"
  [ -f "$clone/.agents/skills/firstmate-calm" ] || fail "refusal still converted another path"
  pass "windows-checkout: repair refuses a file that is not the link target and changes nothing"
}

test_repair_restores_text_when_junction_fails() {
  local clone
  clone=$(make_clone fail)
  if FM_TEST_MKLINK_FAIL=1 run "$WIN_S" "$clone" repair 2>"$TMP/err"; then fail "repair claimed success without a link"; fi
  [ "$(cat "$clone/.claude/skills")" = ../.agents/skills ] || fail "text file not restored"
  pass "windows-checkout: a failed mklink restores the text file"
}

test_undo_restores_and_is_idempotent() {
  local clone ex
  clone=$(make_clone undo)
  run "$WIN_S" "$clone" repair
  run "$WIN_S" "$clone" undo || fail "undo failed"
  [ -f "$clone/.claude/skills" ] && [ ! -L "$clone/.claude/skills" ] || fail "text file not restored"
  [ -f "$clone/.agents/skills/a/SKILL.md" ] || fail "undo touched the target"
  [ -z "$(git -C "$clone" status --porcelain)" ] || fail "status after undo: $(git -C "$clone" status --porcelain)"
  ex=$(git -C "$clone" rev-parse --git-path info/exclude)
  ! grep -q '^/.claude/skills$' "$clone/$ex" || fail "exclude line remains"
  ! git -C "$clone" ls-files -v .claude/skills | grep -q '^S' || fail "skip-worktree remains"
  run "$WIN_S" "$clone" undo || fail "second undo failed"
  pass "windows-checkout: undo restores the tracked files, flags and exclude, and is idempotent"
}

test_bootstrap_reports_and_installs() {
  local clone out
  clone=$(make_clone boot)
  mkdir -p "$TMP/boot-home/config"
  out=$(FM_TEST_UNAME_S=$WIN_S FM_WINCHECKOUT_ROOT=$clone PATH="$FAKEBIN:$PATH" FM_HOME="$TMP/boot-home" \
    FM_ROOT_OVERRIDE="$TMP/boot-home" FM_BOOTSTRAP_NETWORK=skip "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null || true)
  case "$out" in *"MISSING: windows-checkout (install: bin/fm-windows-checkout.sh repair)"*) ;; *) fail "bootstrap did not report the link: $out" ;; esac
  out=$(cd "$ROOT" && FM_TEST_UNAME_S=$WIN_S FM_WINCHECKOUT_ROOT=$clone PATH="$FAKEBIN:$PATH" \
    "$ROOT/bin/fm-bootstrap.sh" install windows-checkout 2>&1)
  [ -d "$clone/.claude/skills/a" ] || fail "bootstrap install did not repair: $out"
  out=$(FM_TEST_UNAME_S=Linux FM_WINCHECKOUT_ROOT=$clone PATH="$FAKEBIN:$PATH" FM_HOME="$TMP/boot-home" \
    FM_ROOT_OVERRIDE="$TMP/boot-home" FM_BOOTSTRAP_NETWORK=skip "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null || true)
  case "$out" in *windows-checkout*) fail "Linux bootstrap mentions windows-checkout: $out" ;; esac
  pass "windows-checkout: bootstrap reports MISSING and install runs repair, only on Windows"
}

test_real_mklink_on_windows() {
  local clone out
  case "$REAL_UNAME_S" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *) pass "skip: real mklink needs a Windows host (uname -s is $REAL_UNAME_S)"; return ;;
  esac
  clone=$(make_clone real)
  FM_WINCHECKOUT_ROOT=$clone bash "$ROOT/bin/fm-windows-checkout.sh" repair || fail "real repair failed"
  [ -d "$clone/.claude/skills/a" ] || fail "real junction missing"
  [ -z "$(git -C "$clone" status --porcelain)" ] || fail "real status not clean"
  git -C "$clone" add -A
  [ -z "$(git -C "$clone" diff --cached --name-only)" ] || fail "real add -A staged files"
  FM_WINCHECKOUT_ROOT=$clone bash "$ROOT/bin/fm-windows-checkout.sh" undo || fail "real undo failed"
  [ -f "$clone/.agents/skills/a/SKILL.md" ] || fail "real undo removed target content"
  out=$(git -C "$clone" status --porcelain)
  [ -z "$out" ] || fail "real status after undo: $out"
  pass "windows-checkout: real mklink repair and undo round trip"
}

fm_test_run \
  test_check_is_silent_off_windows \
  test_check_reports_broken_links_and_autocrlf \
  test_repair_then_check_status_add_and_idempotency \
  test_repair_refuses_user_data \
  test_repair_restores_text_when_junction_fails \
  test_undo_restores_and_is_idempotent \
  test_bootstrap_reports_and_installs \
  test_real_mklink_on_windows
