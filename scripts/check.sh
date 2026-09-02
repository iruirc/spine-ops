#!/usr/bin/env bash
# The invariants nobody was checking. Read-only; exits 1 on any breach.
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

case "${1:-}" in
  -h|--help) sed -n '2p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; echo "usage: $(basename "${BASH_SOURCE[0]}")"; exit 0 ;;
  "") ;;
  *) echo "error: $(basename "${BASH_SOURCE[0]}") takes no arguments" >&2; exit 2 ;;
esac

fail=0
bad() { echo "FAIL  $*"; fail=1; }
good() { echo "ok    $*"; }

mp="$(marketplace_path)"

# 1. Every plugin the marketplace advertises must be reachable on this disk,
#    or a release silently skips it.
while IFS= read -r n; do
  if p="$(jq -r --arg n "$n" '.checkouts[$n].path // empty' "$CONFIG")" && [ -n "$p" ]; then
    good "$n is listed and has a checkout"
  else
    bad "$n is advertised by the marketplace but repos.json has no checkout for it"
  fi
done < <(plugin_names)

# 2. A checkout for something the marketplace no longer lists is stale config.
while IFS= read -r n; do
  plugin_names | grep -qx "$n" || bad "repos.json declares '$n', which the marketplace does not list"
done < <(jq -r '.checkouts | keys[]' "$CONFIG")

# 3. The two places a plugin's version is written must agree. This is the pair
#    that silently drifts: the marketplace is edited by hand, the plugin bumps
#    itself, and nothing has ever compared them.
while IFS= read -r n; do
  d="$(checkout_path "$n")" || continue
  own="$(plugin_version "$d")"; listed="$(listed_version "$n")"
  if [ "$own" = "$listed" ]; then good "$n $own matches the marketplace listing"
  else bad "$n declares $own, the marketplace lists $listed"; fi
done < <(plugin_names)

# 4. A declared version with no tag is a release nobody can check out again.
check_tagged() {
  local label="$1" dir="$2" ver="$3"
  if has_tag "$dir" "$ver"; then good "$label $ver is tagged"
  else bad "$label declares $ver but has no tag $ver"; fi
}
check_tagged marketplace "$mp" "$(marketplace_version)"
while IFS= read -r n; do
  d="$(checkout_path "$n")"; check_tagged "$n" "$d" "$(plugin_version "$d")"
done < <(plugin_names)

# 5. The name in plugin.json is what the manifest binds against.
while IFS= read -r n; do
  d="$(checkout_path "$n")"
  own="$(jq -r '.name' "$d/.claude-plugin/plugin.json")"
  [ "$own" = "$n" ] || bad "checkout at $d calls itself '$own', the marketplace calls it '$n'"
done < <(plugin_names)

exit "$fail"
