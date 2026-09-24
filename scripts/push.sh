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

# Release tags on the branch that origin does not have yet, oldest first. A
# release tag is a version whose commit is `chore: release <version>`; any other
# local tag is somebody's scratch, and pushing it would publish it.
pending_tags() {
  local dir="$1" br="$2" remote t
  remote="$(git -C "$dir" ls-remote --tags origin 2>/dev/null | sed 's#.*refs/tags/##; s#\^{}$##')"
  git -C "$dir" tag --list '[0-9]*.[0-9]*.[0-9]*' --merged "$br" \
    | sort -t. -k1,1n -k2,2n -k3,3n \
    | while IFS= read -r t; do
        is_semver "$t" || continue
        [ "$(git -C "$dir" log -1 --format=%s "$t")" = "chore: release $t" ] || continue
        grep -qxF -- "$t" <<<"$remote" || echo "$t"
      done
}

send() {
  local label="$1" dir="$2" br ahead pending t
  br="$(current_branch "$dir")"
  git -C "$dir" fetch origin --quiet 2>/dev/null || true
  ahead="$(git -C "$dir" rev-list --count "origin/$br..$br" 2>/dev/null || echo 0)"
  pending="$(pending_tags "$dir" "$br" | tr '\n' ' ')"; pending="${pending% }"
  if [ "$ahead" -eq 0 ] && [ -z "$pending" ]; then note "$label: nothing to push"; return; fi
  if [ "$DRY" -eq 1 ]; then note "$label: $ahead commit(s)${pending:+ and tag(s) $pending} would go to origin/$br"; return; fi
  [ "$br" = "main" ] || die "$label is on '$br' — refusing to push a release from a branch"
  git -C "$dir" push --quiet origin "$br"
  for t in $pending; do git -C "$dir" push --quiet origin "refs/tags/$t"; done
  note "$label: $ahead commit(s)${pending:+ and tag(s) $pending} pushed"
}

echo "push:"
# Publish plugin repositories first. The Codex marketplace resolves their
# Git-backed `main` branches, so the catalogue must never arrive before the
# plugin commits it exposes.
while IFS= read -r n; do
  d="$(checkout_path "$n")"
  send "$n" "$d"
done < <(plugin_names)
send marketplace "$(marketplace_path)"
# Not a plugin and never tagged, but it holds the notes the tags are described
# by: left behind, a published release explains itself nowhere.
send spine-ops "$OPS_ROOT"
