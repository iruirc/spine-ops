#!/usr/bin/env bash
# Publish what release.sh prepared: commits and tags, per repository.
# Separate on purpose — a tag on the remote is not withdrawn quietly.
#
#   push.sh --dry-run    say what would go
#   push.sh              send it
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

DRY=0
case "${1:-}" in
  -h|--help) sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  --dry-run) DRY=1 ;;
  "") ;;
  *) echo "error: unrecognized argument '$1'" >&2; exit 2 ;;
esac

send() {
  local label="$1" dir="$2" br ahead tags
  br="$(current_branch "$dir")"
  git -C "$dir" fetch origin --quiet 2>/dev/null || true
  ahead="$(git -C "$dir" rev-list --count "origin/$br..$br" 2>/dev/null || echo 0)"
  tags="$(git -C "$dir" push --tags --dry-run origin 2>&1 | grep -c '\[new tag\]' || true)"
  if [ "$ahead" -eq 0 ] && [ "$tags" -eq 0 ]; then note "$label: nothing to push"; return; fi
  if [ "$DRY" -eq 1 ]; then note "$label: $ahead commit(s), $tags tag(s) would go to origin/$br"; return; fi
  [ "$br" = "main" ] || die "$label is on '$br' — refusing to push a release from a branch"
  git -C "$dir" push --quiet origin "$br"
  git -C "$dir" push --quiet --tags origin
  note "$label: $ahead commit(s) and $tags tag(s) pushed"
}

echo "push:"
while IFS= read -r n; do send "$n" "$(checkout_path "$n")"; done < <(plugin_names)
send marketplace "$(marketplace_path)"
