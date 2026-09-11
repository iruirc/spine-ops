#!/usr/bin/env bats
# A release moves several repositories in step, and its failures are the quiet
# kind: a tag on a commit nothing verified, a bump half-applied, a stray tag
# published. These run the real scripts against throwaway repositories laid out
# like the family: a plugin, the marketplace that lists it, and spine-ops.

mkrepo() {
  mkdir -p "$1"
  git -C "$1" init --quiet -b main
  git -C "$1" config user.email t@example.com
  git -C "$1" config user.name Test
}

commit_all() { git -C "$1" add -A; git -C "$1" commit --quiet -m change; }

setup() {
  W="$(mktemp -d)"
  export VERIFIED_AT="$W/verified-at"

  mkrepo "$W/core"
  mkdir -p "$W/core/.claude-plugin" "$W/core/docs"
  printf '{\n  "name": "core",\n  "version": "1.0.0"\n}\n' > "$W/core/.claude-plugin/plugin.json"
  printf 'Depend on it as:\n\n    { "name": "core", "version": ">=1.0.0 <2" }\n' > "$W/core/docs/driver.md"
  # Records the version it was run at, outside the tree, and fails unless the
  # quoted floor already moved with it — the shape of the real core's own suite.
  cat > "$W/core/verify.sh" <<'SH'
#!/usr/bin/env bash
v="$(jq -r .version .claude-plugin/plugin.json)"
echo "$v" > "$VERIFIED_AT"
grep -q "\"name\": \"core\", \"version\": \">=$v <" docs/driver.md || { echo "floor is not $v"; exit 1; }
SH
  chmod +x "$W/core/verify.sh"
  commit_all "$W/core"; git -C "$W/core" tag 1.0.0

  mkrepo "$W/market"
  mkdir -p "$W/market/.claude-plugin"
  cat > "$W/market/.claude-plugin/marketplace.json" <<'JSON'
{
  "name": "test",
  "version": "1.0.0",
  "plugins": [
    {
      "name": "core",
      "version": "1.0.0"
    }
  ]
}
JSON
  commit_all "$W/market"; git -C "$W/market" tag 1.0.0

  mkdir -p "$W/ops/notes"
  cp -Rp "$BATS_TEST_DIRNAME/../scripts" "$W/ops/scripts"
  cat > "$W/ops/repos.json" <<'JSON'
{
  "marketplace": { "path": "../market" },
  "checkouts": {
    "core": { "path": "../core", "verify": "./verify.sh", "floor_files": ["docs/driver.md"] }
  }
}
JSON
  echo "- the change" > "$W/ops/notes/core-1.1.0.md"
  mkrepo "$W/ops"; commit_all "$W/ops"
}

teardown() { rm -rf "$W"; }

give_origins() {
  local r
  for r in core market ops; do
    git init --quiet --bare -b main "$W/$r.git"
    git -C "$W/$r" remote add origin "$W/$r.git"
    git -C "$W/$r" push --quiet origin main
  done
}

@test "the release commit carries the floor, and verify ran at the version being tagged" {
  run "$W/ops/scripts/release.sh" core=minor
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat "$VERIFIED_AT")" = "1.1.0" ]
  [ "$(git -C "$W/core" show --format= --name-only 1.1.0 | sort | tr '\n' ' ')" = ".claude-plugin/plugin.json docs/driver.md " ]
  grep -q '"name": "core", "version": ">=1.1.0 <2"' "$W/core/docs/driver.md"
  [ -z "$(git -C "$W/core" status --porcelain)" ]
}

@test "a failed verification says why and leaves every repository as it was" {
  printf '#!/usr/bin/env bash\necho "verify said no"\nexit 1\n' > "$W/core/verify.sh"
  commit_all "$W/core"
  core_head="$(git -C "$W/core" rev-parse HEAD)"
  market_head="$(git -C "$W/market" rev-parse HEAD)"

  run "$W/ops/scripts/release.sh" core=minor
  [ "$status" -ne 0 ]
  [[ "$output" == *"verify said no"* ]] || { echo "$output"; return 1; }
  [ "$(git -C "$W/core" rev-parse HEAD)" = "$core_head" ]
  [ "$(git -C "$W/market" rev-parse HEAD)" = "$market_head" ]
  [ -z "$(git -C "$W/core" status --porcelain)" ]
  [ -z "$(git -C "$W/market" status --porcelain)" ]
  run git -C "$W/core" rev-parse -q --verify refs/tags/1.1.0
  [ "$status" -ne 0 ]
}

@test "push publishes the release tags and leaves other local tags behind" {
  give_origins
  "$W/ops/scripts/release.sh" core=minor >/dev/null
  git -C "$W/core" tag experiment

  run "$W/ops/scripts/push.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  git -C "$W/core.git" rev-parse -q --verify refs/tags/1.1.0
  git -C "$W/market.git" rev-parse -q --verify refs/tags/1.1.0
  run git -C "$W/core.git" rev-parse -q --verify refs/tags/experiment
  [ "$status" -ne 0 ]
}
