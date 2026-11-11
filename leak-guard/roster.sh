#!/usr/bin/env bash
# Which checkouts leak-guard guards, and whether their hooks are installed.
# Sourced, never executed (install-hooks.sh, release.sh, push.sh, status.sh).
#
# The roster is the plugins of the marketplace manifest, the marketplace itself
# and spine-ops itself: every repo whose commits reach the public. It comes from
# lib.sh, so there is no second list to drift from the first.

[ -n "${BASH_VERSION:-}" ] || { echo "roster.sh is bash: source it from a bash script" >&2; return 1 2>/dev/null || exit 1; }

LEAK_GUARD_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=../scripts/lib.sh
. "$LEAK_GUARD_DIR/../scripts/lib.sh"

# The hooks folder of THIS spine-ops, physical and absolute: the one value
# core.hooksPath must hold in every clone.
leak_hooks_dir() { ( cd -P -- "$LEAK_GUARD_DIR/hooks" && pwd -P ); }

# One line per guarded repo: "<name>TAB<absolute dir>". A plugin goes by its
# plugin name; the marketplace and spine-ops by the name of their folder.
leak_roster() {
  local names n d
  names="$(plugin_names)" || return 1
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    d="$(checkout_path "$n")" || return 1
    printf '%s\t%s\n' "$n" "$d"
  done <<<"$names"
  d="$(marketplace_path)" || return 1
  printf '%s\t%s\n' "$(basename -- "$d")" "$d"
  printf '%s\t%s\n' "$(basename -- "$OPS_ROOT")" "$OPS_ROOT"
}

# State of the hooks in one clone, from its LOCAL config only (a global
# core.hooksPath is not ours to read as "installed" or to overwrite):
#   ok          core.hooksPath is this spine-ops's hooks folder
#   missing     core.hooksPath is not set
#   broken path core.hooksPath names a folder that does not exist
#   foreign     core.hooksPath names some other existing folder
# Paths are compared as physical absolute paths, so a symlinked checkout of
# spine-ops, a trailing slash or a relative value do not read as "foreign".
leak_hooks_state() {
  local dir="$1" v p
  v="$(git -C "$dir" config --local --type=path --get core.hooksPath 2>/dev/null)" || v=""
  [ -n "$v" ] || { echo missing; return 0; }
  case "$v" in /*) ;; *) v="$dir/$v" ;; esac
  p="$( cd -P -- "$v" 2>/dev/null && pwd -P )" || { echo "broken path"; return 0; }
  if [ "$p" = "$(leak_hooks_dir)" ]; then echo ok; else echo foreign; fi
}

# 0 iff the hooks are installed in <dir>.
leak_hooks_ok() { [ "$(leak_hooks_state "$1")" = ok ]; }

# The stoplist is found the way scan.sh finds it (this mirrors one line of it);
# whether it is usable is scan.sh's own verdict.
leak_stoplist_path() { printf '%s\n' "${LEAK_GUARD_STOPLIST:-$LEAK_GUARD_DIR/../../spine-notes/leak-guard/stoplist.txt}"; }
