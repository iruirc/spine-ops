#!/usr/bin/env bash
# Point every public checkout at this spine-ops's git hooks, or check that it still does.
#
#   install-hooks.sh            set core.hooksPath (local config of each clone) where it is
#                               not set or points at a folder that is gone; leave a
#                               core.hooksPath that names some other folder, say which repo
#                               and exit 1 once the others are done
#   install-hooks.sh --check    print the state and exit 1 unless every repo's hooks and the
#                               stoplist are ok
#
# Repos: every plugin of the marketplace, the marketplace, spine-ops itself.
# Hooks per repo:  ok | missing | broken path | foreign
# Stoplist:        ok (N records) | missing | invalid      (see scan.sh for where it lives)
# Git's global config is never touched.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=roster.sh
. "$HERE/roster.sh"

usage() { sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

MODE=install
case "${1:-}" in
  "") ;;
  --check) MODE=check ;;
  -h|--help) usage; exit 0 ;;
  *) echo "error: unrecognized argument '$1'" >&2; usage >&2; exit 2 ;;
esac
[ $# -le 1 ] || { echo "error: too many arguments" >&2; exit 2; }

ROSTER="$(leak_roster)" || exit 1
HOOKS="$(leak_hooks_dir)"

# --- install ---------------------------------------------------------------

do_install() {
  local name dir state changed=0 foreign=0 bad=0 cur
  while IFS=$'\t' read -r name dir; do
    if ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
      note "$name: not a git repository ($dir)"
      bad=1
      continue
    fi
    state="$(leak_hooks_state "$dir")"
    case "$state" in
      ok) note "$name: ok" ;;
      missing|"broken path")
        git -C "$dir" config --local core.hooksPath "$HOOKS"
        note "$name: installed (was $state)"
        changed=1 ;;
      foreign)
        cur="$(git -C "$dir" config --local --get core.hooksPath)"
        note "$name: foreign core.hooksPath ($cur), left alone"
        foreign=1 ;;
    esac
  done <<<"$ROSTER"
  if [ "$foreign" -eq 1 ]; then
    echo "error: a repo has a core.hooksPath that is not ours; remove it there if it should be replaced" >&2
  fi
  [ "$changed" -eq 1 ] || [ "$foreign" -eq 1 ] || [ "$bad" -eq 1 ] || echo "nothing to do: the hooks are installed everywhere"
  [ "$foreign" -eq 0 ] && [ "$bad" -eq 0 ]
}

# --- check -----------------------------------------------------------------

do_check() {
  local name dir state fail=0 sl sl_state sl_count

  echo "hooks:"
  while IFS=$'\t' read -r name dir; do
    state="$(leak_hooks_state "$dir")"
    printf '  %-24s %s\n' "$name" "$state"
    [ "$state" = ok ] || fail=1
  done <<<"$ROSTER"

  sl="$(leak_stoplist_path)"
  if [ ! -f "$sl" ]; then
    sl_state=missing
  elif ( cd "$OPS_ROOT" && bash "$HERE/scan.sh" --validate ) >/dev/null 2>&1; then
    sl_count="$(awk '{ sub(/\r$/, "") } !/^[ \t]*(#|$)/ { n++ } END { print n + 0 }' "$sl")"
    sl_state="ok ($sl_count records)"
  else
    sl_state=invalid
  fi
  echo "stoplist: $sl_state"
  echo "  path: $sl"
  case "$sl_state" in ok*) ;; *) fail=1 ;; esac

  [ "$fail" -eq 0 ]
}

case "$MODE" in
  install) do_install ;;
  check) do_check ;;
esac
