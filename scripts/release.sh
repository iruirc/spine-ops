#!/usr/bin/env bash
# Bump, commit, tag. Stops there: pushing is push.sh, because a published tag
# is not withdrawn quietly.
#
#   release.sh minor                        every repo with work since its last tag
#   release.sh minor swift-platform=patch   same, one overridden
#   release.sh spine-toolkit=minor          only that one
#   release.sh spine-toolkit=1.3.0          an explicit version, when a bump is not what you mean
#
# The marketplace is never optional: any plugin bump rewrites its listing, so it
# is released alongside, at the highest increment of the release unless told
# otherwise with marketplace=<kind|version>.
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

DRY=0
DEFAULT_KIND=""
EXPLICIT=""   # lines: name<TAB>value

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    major|minor|patch) DEFAULT_KIND="$arg" ;;
    *=*) EXPLICIT="$EXPLICIT${arg%%=*}	${arg#*=}
" ;;
    *) die "unrecognized argument '$arg'" ;;
  esac
done
[ -n "$DEFAULT_KIND" ] || [ -n "$EXPLICIT" ] || die "nothing asked for: give an increment, or name=<kind|version>"

explicit_for() { printf '%s' "$EXPLICIT" | awk -F'\t' -v n="$1" '$1 == n {print $2; exit}'; }

# A name nobody knows must not read as an empty release. Checked before the plan,
# so a typo says so instead of reporting there is nothing to do.
while IFS=$'\t' read -r n _; do
  [ -n "$n" ] || continue
  [ "$n" = marketplace ] || plugin_names | grep -qx "$n" \
    || die "no plugin named '$n' — the marketplace lists: $(plugin_names | tr '\n' ' ')"
done <<<"$EXPLICIT"
kind_rank() { case "$1" in patch) echo 1 ;; minor) echo 2 ;; major) echo 3 ;; *) echo 0 ;; esac; }

resolve_target() {  # name current_version -> "to<TAB>kind"
  local name="$1" cur="$2" want; want="$(explicit_for "$name")"
  [ -n "$want" ] || want="$DEFAULT_KIND"
  if is_semver "$want"; then echo "$want	explicit"
  else echo "$(bump "$cur" "$want")	$want"; fi
}

# --- plan ------------------------------------------------------------------

PLAN=""       # name<TAB>dir<TAB>from<TAB>to<TAB>kind<TAB>commits
TOP_RANK=0
mp="$(marketplace_path)"

while IFS= read -r name; do
  dir="$(checkout_path "$name")"
  cur="$(plugin_version "$dir")"
  want="$(explicit_for "$name")"
  n="$(unreleased_count "$dir")"
  if [ -z "$want" ]; then
    [ -n "$DEFAULT_KIND" ] || continue          # only named repos were asked for
    [ "$n" -gt 0 ] || continue                  # nothing to release here
  fi
  IFS=$'\t' read -r to kind <<<"$(resolve_target "$name" "$cur")"
  semver_gt "$to" "$cur" || die "$name: $to is not above the current $cur"
  ! has_tag "$dir" "$to" || die "$name already has a tag $to"
  r="$(kind_rank "$kind")"; [ "$r" -le "$TOP_RANK" ] || TOP_RANK="$r"
  PLAN="$PLAN$name	$dir	$cur	$to	$kind	$n
"
done < <(plugin_names)

[ -n "$PLAN" ] || die "no plugin has anything to release (see status.sh)"

mp_cur="$(marketplace_version)"
mp_want="$(explicit_for marketplace)"
if [ -z "$mp_want" ]; then
  case "$TOP_RANK" in 3) mp_want=major ;; 2) mp_want=minor ;; *) mp_want=patch ;; esac
fi
if is_semver "$mp_want"; then mp_to="$mp_want"; else mp_to="$(bump "$mp_cur" "$mp_want")"; fi
semver_gt "$mp_to" "$mp_cur" || die "marketplace: $mp_to is not above the current $mp_cur"
! has_tag "$mp" "$mp_to" || die "marketplace already has a tag $mp_to"

echo "plan:"
while IFS=$'\t' read -r name dir from to kind n; do
  [ -n "$name" ] || continue
  printf '  %-16s %-7s -> %-7s %-6s %s commit(s)  notes/%s-%s.md\n' "$name" "$from" "$to" "$kind" "$n" "$name" "$to"
done <<<"$PLAN"
printf '  %-16s %-7s -> %-7s %-6s (body generated)\n' marketplace "$mp_cur" "$mp_to" "$mp_want"
echo

# --- guards, before anything is touched ------------------------------------

echo "guards:"
while IFS=$'\t' read -r name dir from to kind n; do
  [ -n "$name" ] || continue
  guard_release_ready "$name" "$dir"; note "$name: on main, clean, not behind"
done <<<"$PLAN"
guard_release_ready marketplace "$mp"; note "marketplace: on main, clean, not behind"

missing=""
while IFS=$'\t' read -r name dir from to kind n; do
  [ -n "$name" ] || continue
  f="$OPS_ROOT/notes/$name-$to.md"
  [ -s "$f" ] || missing="$missing  $f
"
done <<<"$PLAN"
if [ -n "$missing" ]; then
  echo
  echo "the release body for each plugin is a file, and these are missing or empty:"
  printf '%s' "$missing"
  echo "write them, then run the same command again."
  [ "$DRY" -eq 1 ] || exit 2
else
  note "release notes present for every plugin"
fi

[ "$DRY" -eq 0 ] || { echo; echo "--dry-run: stopping before verification and any change."; exit 0; }

echo
echo "verify:"
while IFS=$'\t' read -r name dir from to kind n; do
  [ -n "$name" ] || continue
  cmd="$(verify_cmd "$name")"
  [ -n "$cmd" ] || { note "$name: no verify declared — skipped"; continue; }
  ( cd "$dir" && eval "$cmd" ) >/dev/null || die "$name failed its own verification; nothing was changed"
  note "$name: $cmd passed"
done <<<"$PLAN"

# --- apply -----------------------------------------------------------------

echo
echo "release:"
while IFS=$'\t' read -r name dir from to kind n; do
  [ -n "$name" ] || continue
  "$OPS_ROOT/scripts/set-version.py" "$dir/.claude-plugin/plugin.json" "$to"
  git -C "$dir" add .claude-plugin/plugin.json
  git -C "$dir" commit --quiet -F - <<COMMIT
chore: release $to

$(cat "$OPS_ROOT/notes/$name-$to.md")
COMMIT
  git -C "$dir" tag "$to"
  note "$name $to committed and tagged ($(git -C "$dir" rev-parse --short HEAD))"
done <<<"$PLAN"

body="Plugin versions this release carries:"
while IFS=$'\t' read -r name dir from to kind n; do
  [ -n "$name" ] || continue
  "$OPS_ROOT/scripts/set-version.py" "$(manifest)" "$to" --plugin "$name"
  body="$body
- $name $from -> $to"
done <<<"$PLAN"
"$OPS_ROOT/scripts/set-version.py" "$(manifest)" "$mp_to"
git -C "$mp" add .claude-plugin/marketplace.json
git -C "$mp" commit --quiet -F - <<COMMIT
chore: release $mp_to

$body
COMMIT
git -C "$mp" tag "$mp_to"
note "marketplace $mp_to committed and tagged ($(git -C "$mp" rev-parse --short HEAD))"

echo
echo "nothing is pushed. review, then: scripts/push.sh"
