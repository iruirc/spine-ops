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
  local label="$1" dir="$2" tag="$3" br ahead pending=""
  br="$(current_branch "$dir")"
  git -C "$dir" fetch origin --quiet 2>/dev/null || true
  ahead="$(git -C "$dir" rev-list --count "origin/$br..$br" 2>/dev/null || echo 0)"
  # The release tag is the version the manifest declares. Any other local tag is
  # somebody's scratch, and pushing it would publish it.
  if [ -n "$tag" ] && has_tag "$dir" "$tag" \
    && ! git -C "$dir" ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
    pending="$tag"
  fi
  if [ "$ahead" -eq 0 ] && [ -z "$pending" ]; then note "$label: nothing to push"; return; fi
  if [ "$DRY" -eq 1 ]; then note "$label: $ahead commit(s)${pending:+ and tag $pending} would go to origin/$br"; return; fi
  [ "$br" = "main" ] || die "$label is on '$br' — refusing to push a release from a branch"
  git -C "$dir" push --quiet origin "$br"
  [ -z "$pending" ] || git -C "$dir" push --quiet origin "refs/tags/$pending"
  note "$label: $ahead commit(s)${pending:+ and tag $pending} pushed"
}

echo "push:"
while IFS= read -r n; do
  d="$(checkout_path "$n")"
  send "$n" "$d" "$(plugin_version "$d")"
done < <(plugin_names)
send marketplace "$(marketplace_path)" "$(marketplace_version)"
# Not a plugin and never tagged, but it holds the notes the tags are described
# by: left behind, a published release explains itself nowhere.
send spine-ops "$OPS_ROOT" ""
