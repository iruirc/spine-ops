#!/usr/bin/env bash
# What state is the family in? Read-only.
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

case "${1:-}" in
  -h|--help) sed -n '2p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; echo "usage: $(basename "${BASH_SOURCE[0]}")"; exit 0 ;;
  "") ;;
  *) echo "error: $(basename "${BASH_SOURCE[0]}") takes no arguments" >&2; exit 2 ;;
esac

row() {
  local name="$1" dir="$2" ver="$3"
  printf '%-16s %-8s %-7s %-9s %-8s %s\n' \
    "$name" "$ver" "$(latest_tag "$dir" || echo -)" \
    "$(current_branch "$dir")" "$(ahead_behind "$dir")" \
    "$(is_clean "$dir" && echo clean || echo DIRTY)"
}

printf '%-16s %-8s %-7s %-9s %-8s %s\n' REPO VERSION TAG BRANCH AH/BE TREE
mp="$(marketplace_path)"
row marketplace "$mp" "$(marketplace_version)"
while IFS= read -r n; do
  d="$(checkout_path "$n")"
  row "$n" "$d" "$(plugin_version "$d")"
done < <(plugin_names)

echo
echo "unreleased commits since the highest tag:"
note "marketplace: $(unreleased_count "$mp")"
while IFS= read -r n; do
  note "$n: $(unreleased_count "$(checkout_path "$n")")"
done < <(plugin_names)
