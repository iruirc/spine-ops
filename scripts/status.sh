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
  printf '%-26s %-8s %-7s %-9s %-8s %s\n' \
    "$name" "$ver" "$(latest_tag "$dir" || echo -)" \
    "$(current_branch "$dir")" "$(ahead_behind "$dir")" \
    "$(is_clean "$dir" && echo clean || echo DIRTY)"
}

printf '%-26s %-8s %-7s %-9s %-8s %s\n' REPO VERSION TAG BRANCH AH/BE TREE
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

# What leak-guard says about the hooks and the stoplist. Read-only, and never
# fails the table above: a red line here is information, not an error.
echo
echo "leak-guard:"
guard_out="$("$OPS_ROOT/leak-guard/install-hooks.sh" --check 2>&1 </dev/null)" || true
printf '%s\n' "$guard_out" | sed 's/^/  /'

# The folder above the checkouts is not a repository, so the file that loads WORKSPACE.md into
# every Claude Code session started there is lost with each new clone, and so is the symlink through
# which Codex gets WORKSPACE.md. Information, like the above.
echo
echo "workspace:"
import="@$(basename -- "$OPS_ROOT")/WORKSPACE.md"
claude_md="$(dirname -- "$OPS_ROOT")/CLAUDE.md"
if [ ! -f "$claude_md" ]; then state=missing
elif grep -qxF -- "$import" "$claude_md"; then state=ok
else state="no import"
fi
printf '  %-26s %s\n' CLAUDE.md "$state"
[ "$state" = ok ] || note "  fix, from the folder above the checkouts: printf '$import\\n' >> CLAUDE.md"
agents_md="$(dirname -- "$OPS_ROOT")/AGENTS.md"
if [ -L "$agents_md" ] && [ "$agents_md" -ef "$OPS_ROOT/WORKSPACE.md" ]; then state=ok
elif [ ! -e "$agents_md" ] && [ ! -L "$agents_md" ]; then state=missing
else state="not a link"
fi
printf '  %-26s %s\n' AGENTS.md "$state"
[ "$state" = ok ] || note "  fix, from the folder above the checkouts: ln -s $(basename -- "$OPS_ROOT")/WORKSPACE.md AGENTS.md"
exit 0
