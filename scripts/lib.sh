#!/usr/bin/env bash
# Shared by every command here. Sourced, never executed.
#
# One rule shapes the rest: the roster of plugins comes from the marketplace's
# own manifest, and repos.json says only where those plugins sit on this disk.
# A second roster would drift from the first, which is how the marketplace went
# a whole release without a tag.

set -euo pipefail

OPS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$OPS_ROOT/repos.json"

die() { echo "error: $*" >&2; exit 1; }
note() { echo "  $*"; }

[ -f "$CONFIG" ] || die "no repos.json at $CONFIG"
command -v jq >/dev/null || die "jq is required"

# --- the config: paths only ------------------------------------------------

marketplace_path() {
  local p; p="$(jq -r '.marketplace.path' "$CONFIG")"
  [ "$p" != "null" ] || die "repos.json declares no marketplace path"
  ( cd "$OPS_ROOT/$p" && pwd ) 2>/dev/null || die "marketplace checkout not found: $OPS_ROOT/$p"
}

checkout_path() {
  local name="$1" p
  p="$(jq -r --arg n "$name" '.checkouts[$n].path // empty' "$CONFIG")"
  [ -n "$p" ] || die "repos.json has no checkout for '$name' — add it, or the release cannot reach that plugin"
  ( cd "$OPS_ROOT/$p" && pwd ) 2>/dev/null || die "checkout for '$name' not found: $OPS_ROOT/$p"
}

verify_cmd() { jq -r --arg n "$1" '.checkouts[$n].verify // empty' "$CONFIG"; }

# --- the roster: from the marketplace manifest -----------------------------

manifest() { echo "$(marketplace_path)/.claude-plugin/marketplace.json"; }

plugin_names() { jq -r '.plugins[].name' "$(manifest)"; }

# Version a plugin is listed at IN THE MARKETPLACE, which is a different fact
# from the version its own plugin.json carries. check.sh exists because the two
# can disagree.
listed_version() { jq -r --arg n "$1" '.plugins[] | select(.name == $n) | .version' "$(manifest)"; }

marketplace_version() { jq -r '.version' "$(manifest)"; }

plugin_version() {
  local f="$1/.claude-plugin/plugin.json"
  [ -f "$f" ] || die "no plugin.json under $1"
  jq -r '.version' "$f"
}

# --- semver ----------------------------------------------------------------

is_semver() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

# Highest semver tag in a checkout, empty when it has none. `git describe` is
# wrong here: it answers "nearest tag by topology", and a release asks "what is
# the highest version so far".
latest_tag() {
  git -C "$1" tag --list '[0-9]*.[0-9]*.[0-9]*' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1
}

bump() {
  local v="$1" kind="$2" major minor patch
  is_semver "$v" || die "cannot bump '$v': not a semver"
  IFS=. read -r major minor patch <<<"$v"
  case "$kind" in
    major) echo "$((major + 1)).0.0" ;;
    minor) echo "$major.$((minor + 1)).0" ;;
    patch) echo "$major.$minor.$((patch + 1))" ;;
    *) die "unknown increment '$kind' (want major, minor or patch)" ;;
  esac
}

semver_gt() {
  [ "$1" != "$2" ] || return 1
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" = "$1" ]
}

# --- git state -------------------------------------------------------------

current_branch() { git -C "$1" branch --show-current; }
is_clean() { [ -z "$(git -C "$1" status --porcelain)" ]; }
has_tag() { git -C "$1" rev-parse -q --verify "refs/tags/$2" >/dev/null 2>&1; }

# Commits since the highest tag — how a bare `release.sh minor` decides which
# repositories have anything to release at all. No tag yet means everything.
unreleased_count() {
  local dir="$1" tag; tag="$(latest_tag "$dir")"
  if [ -n "$tag" ]; then git -C "$dir" rev-list --count "$tag..HEAD"
  else git -C "$dir" rev-list --count HEAD; fi
}

ahead_behind() {
  local dir="$1" br; br="$(current_branch "$dir")"
  if git -C "$dir" rev-parse -q --verify "origin/$br" >/dev/null 2>&1; then
    echo "$(git -C "$dir" rev-list --count "origin/$br..$br")/$(git -C "$dir" rev-list --count "$br..origin/$br")"
  else
    echo "-/-"
  fi
}

# Refuses everything a release must not start from. Fetch first: "not behind"
# is a claim about the remote, and a stale remote-tracking ref cannot support it.
guard_release_ready() {
  local name="$1" dir="$2" br
  git -C "$dir" fetch origin --quiet 2>/dev/null || true
  br="$(current_branch "$dir")"
  [ "$br" = "main" ] || die "$name is on '$br', not main"
  is_clean "$dir" || die "$name has uncommitted changes"
  if git -C "$dir" rev-parse -q --verify "origin/$br" >/dev/null 2>&1; then
    [ "$(git -C "$dir" rev-list --count "$br..origin/$br")" -eq 0 ] \
      || die "$name is behind origin/$br — pull before releasing"
  fi
}
