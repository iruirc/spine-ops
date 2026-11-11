#!/usr/bin/env bash
# Put the stoplist into the LEAK_STOPLIST secret of every public repo, so the CI
# scan can use it.
#
#   sync-leak-secret.sh
#
# Checks the stoplist first (scan.sh --validate) and uploads nothing when it is
# not valid. Then, for each repo of the roster, runs
#   gh secret set LEAK_STOPLIST -R <owner>/<repo>
# with the stoplist file as stdin; owner and repo come from the origin URL.
# Prints "<repo> ok" or "<repo> failed" and nothing else: the stoplist and gh's
# own messages are never shown. Exit 1 if any repo failed.
# Stoplist: $LEAK_GUARD_STOPLIST, else the default place (see scan.sh).
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=roster.sh
. "$HERE/roster.sh"

usage() { sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

case "${1:-}" in
  "") ;;
  -h|--help) usage; exit 0 ;;
  *) echo "error: unrecognized argument '$1'" >&2; usage >&2; exit 2 ;;
esac

command -v gh >/dev/null 2>&1 || { echo "error: gh is not installed" >&2; exit 1; }

SL="$(leak_stoplist_path)"
[ -f "$SL" ] || { echo "error: no stoplist (set LEAK_GUARD_STOPLIST, or see scan.sh for the default place)" >&2; exit 1; }

# scan.sh's verdict, and its message: it does not print records.
( cd "$OPS_ROOT" && LEAK_GUARD_STOPLIST="$SL" bash "$HERE/scan.sh" --validate ) || {
  echo "error: the stoplist is not valid, nothing was uploaded" >&2
  exit 1
}

ROSTER="$(leak_roster)" || exit 1

failed=0
while IFS=$'\t' read -r name dir; do
  slug="$(leak_repo_slug "$dir")"
  if [ -n "$slug" ] && gh secret set LEAK_STOPLIST -R "$slug" <"$SL" >/dev/null 2>&1; then
    echo "$name ok"
  else
    echo "$name failed"
    failed=1
  fi
done <<<"$ROSTER"

[ "$failed" -eq 0 ]
