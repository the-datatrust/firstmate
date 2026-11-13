#!/usr/bin/env bash
# fm-windows-checkout.sh - check, repair or undo this clone's directory links on
# native Windows (Git Bash, MSYS or Cygwin).
#
# Usage:
#   fm-windows-checkout.sh check    report broken links; always exits 0
#   fm-windows-checkout.sh repair   replace each broken link with a junction
#   fm-windows-checkout.sh undo     put the tracked text files back
#   fm-windows-checkout.sh --help
#
# First choice: turn on Windows Developer Mode, set `git config core.symlinks
# true` and re-checkout, so git makes real symlinks. Junction repair is the
# fallback for machines that cannot do that.
#
# Why: without Developer Mode, git cannot create symlinks, so a tracked symlink
# checks out as a text file holding its target. Only the two DIRECTORY links
# matter to the Claude-only setup: .claude/skills and
# .agents/skills/firstmate-calm. The two `.pi/extensions/lib/*.ts` file links
# are Pi-only and are deliberately left alone.
#
# check: on any other platform (uname -s not MINGW*, MSYS* or CYGWIN*) it prints
# nothing. On Windows it prints one line per finding:
#   WINDOWS_CHECKOUT: broken-link <path> (text file, not a directory link; first choice: Developer Mode + core.symlinks=true and re-checkout; fallback: bin/fm-windows-checkout.sh repair)
# When core.symlinks is not true the hint gains "core.symlinks=<value or unset>;".
#   WINDOWS_CHECKOUT: autocrlf core.autocrlf=true can rewrite line endings; clone with core.autocrlf=false (.gitattributes already pins the important types)
# fm-bootstrap.sh turns a broken-link line into a MISSING: windows-checkout line.
#
# repair: idempotent. For each link path it
#   1. skips a path that is already a directory,
#   2. refuses (exit 1, nothing changed) a path that is a regular file whose bytes
#      differ from the tracked link target, so user data is never deleted,
#   3. removes the text file, makes a junction with `cmd /c mklink /J` (needs no
#      admin; the single slash matters), and checks the directory exists rather
#      than trusting the exit code, restoring the text file if it does not,
#   4. runs `git update-index --skip-worktree <path>` so status stays clean,
#   5. appends `/<path>` once to the repo's info/exclude, because skip-worktree
#      alone lets `git add -A` follow the junction and stage the target's files.
#   It is all-or-nothing: if any link fails, the links this run created are
#   removed and their text files restored, and the failure message includes
#   mklink's own output.
#
# undo: idempotent inverse. A junction is removed with `cmd /c rmdir`, which
# removes only the link and never the target's contents; a real directory is
# refused. Then it clears skip-worktree and restores the tracked text file with
# `git checkout -- <path>`. It leaves the info/exclude lines in place: that file
# lives in the common git dir, so it is shared by every worktree of the clone,
# and removing a line would unprotect another worktree that still has a junction.
# An exclude line has no effect on a tracked text file. Run undo before a
# `git pull` that retargets or deletes a link, which otherwise aborts.
#
# FM_WINCHECKOUT_ROOT selects the repository (default: this script's checkout).
set -eu

LINKS='.claude/skills
.agents/skills/firstmate-calm'

die() {
  printf 'fm-windows-checkout.sh: %s\n' "$*" >&2
  exit 1
}

usage() {
  sed -n "2,/^set -eu/{/^set -eu/!p;}" "$0" | sed "s/^# \{0,1\}//"
}

is_windows() {
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

cmd_arg=${1:-}
case "$cmd_arg" in
  -h|--help) usage; exit 0 ;;
  check|repair|undo) ;;
  *) printf 'usage: fm-windows-checkout.sh check|repair|undo|--help\n' >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
is_windows || { [ "$cmd_arg" = check ] && exit 0; die "$cmd_arg is for Windows (Git Bash, MSYS or Cygwin) only"; }

TOP=$(git -C "${FM_WINCHECKOUT_ROOT:-$SCRIPT_DIR/..}" rev-parse --show-toplevel) \
  || die "not inside a git checkout"
cd "$TOP"

# The tracked link target (a mode 120000 blob), or nothing when not a tracked link.
link_target() {  # <path>
  local mode
  mode=$(git ls-files -s -- "$1" | awk '{print $1; exit}')
  [ "$mode" = 120000 ] || return 1
  git cat-file blob ":$1"
}

winpath() {  # <path>
  cygpath -w "$1"
}

EXCLUDE=$(git rev-parse --git-path info/exclude)

if [ "$cmd_arg" = check ]; then
  symlinks=$(git config --get core.symlinks 2>/dev/null || true)
  while IFS= read -r p; do
    link_target "$p" >/dev/null || continue
    if [ ! -d "$p" ]; then
      note=
      [ "$symlinks" = true ] || note="core.symlinks=${symlinks:-unset}; "
      printf 'WINDOWS_CHECKOUT: broken-link %s (text file, not a directory link; %sfirst choice: Developer Mode + core.symlinks=true and re-checkout; fallback: bin/fm-windows-checkout.sh repair)
' "$p" "$note"
    fi
  done <<< "$LINKS"
  if [ "$(git config --get core.autocrlf 2>/dev/null || true)" = true ]; then
    printf 'WINDOWS_CHECKOUT: autocrlf core.autocrlf=true can rewrite line endings; clone with core.autocrlf=false (.gitattributes already pins the important types)
'
  fi
  exit 0
fi

if [ "$cmd_arg" = repair ]; then
  # Validate every path before changing any.
  while IFS= read -r p; do
    target=$(link_target "$p") || continue
    [ -d "$p" ] && continue
    if [ -e "$p" ] || [ -L "$p" ]; then
      [ -f "$p" ] && [ ! -L "$p" ] && [ "$(cat "$p")" = "$target" ]         || die "refusing $p: not a regular file holding the link target '$target'"
    fi
  done <<< "$LINKS"
  converted=
  rollback() {  # <message>: undo this run's links, then fail
    local q qt
    for q in $converted; do
      MSYS_NO_PATHCONV=1 cmd /c rmdir "$(winpath "$TOP/$q")" >/dev/null 2>&1 || true
      qt=$(link_target "$q") || continue
      [ -e "$q" ] || [ -L "$q" ] || printf '%s' "$qt" > "$q"
    done
    die "$1"
  }
  while IFS= read -r p; do
    target=$(link_target "$p") || continue
    [ -d "$p" ] && continue
    abs=$(cd "$(dirname "$p")" && cd "$target" && pwd) || rollback "link target of $p does not exist: $target"
    rm -f "$p"
    mkdir -p "$(dirname "$p")"
    err=$(MSYS_NO_PATHCONV=1 cmd /c mklink /J "$(winpath "$TOP/$p")" "$(winpath "$abs")" 2>&1 || true)
    if [ ! -d "$p" ]; then
      printf '%s' "$target" > "$p"
      rollback "could not create a junction at $p (mklink said: ${err:-nothing}); restored every text file changed in this run"
    fi
    converted="$converted $p"
  done <<< "$LINKS"
  mkdir -p "$(dirname "$EXCLUDE")"
  touch "$EXCLUDE"
  while IFS= read -r p; do
    link_target "$p" >/dev/null || continue
    git update-index --skip-worktree -- "$p"
    grep -Fxq "/$p" "$EXCLUDE" || printf '/%s
' "$p" >> "$EXCLUDE"
  done <<< "$LINKS"
  exit 0
fi

# undo
while IFS= read -r p; do
  target=$(link_target "$p") || continue
  if [ -L "$p" ]; then
    MSYS_NO_PATHCONV=1 cmd /c rmdir "$(winpath "$TOP/$p")" >/dev/null 2>&1 || true
    [ ! -e "$p" ] && [ ! -L "$p" ] || die "could not remove the junction at $p"
  elif [ -d "$p" ]; then
    die "refusing $p: a real directory, not a junction"
  fi
  git update-index --no-skip-worktree -- "$p"
  [ -e "$p" ] || git checkout -- "$p"
done <<< "$LINKS"
