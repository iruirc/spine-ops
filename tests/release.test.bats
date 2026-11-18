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
  export VERIFIED_AT="$W/verified-at" RAN_FULL="$W/ran-full" TOUCHED_ARGS="$W/touched-args"

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
echo full > "$RAN_FULL"
grep -q "\"name\": \"core\", \"version\": \">=$v <" docs/driver.md || { echo "floor is not $v"; exit 1; }
SH
  # The run a stamped tree gets instead: records the files it was handed.
  printf '#!/usr/bin/env bash\necho "$*" > "$TOUCHED_ARGS"\nexit "${TOUCHED_RC:-0}"\n' > "$W/core/touched.sh"
  chmod +x "$W/core/verify.sh" "$W/core/touched.sh"
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
  cp -Rp "$BATS_TEST_DIRNAME/../leak-guard" "$W/ops/leak-guard"
  cat > "$W/ops/repos.json" <<'JSON'
{
  "marketplace": { "path": "../market" },
  "checkouts": {
    "core": { "path": "../core", "verify": "./verify.sh", "verify_touched": "./touched.sh",
              "floor_files": ["docs/driver.md"] }
  }
}
JSON
  echo "- the change" > "$W/ops/notes/core-1.1.0.md"
  mkrepo "$W/ops"; commit_all "$W/ops"

  # release.sh and push.sh refuse without leak-guard: a one-record stoplist, the
  # hooks in every fixture repo.
  printf 'word Gizmo\n' > "$W/stoplist.txt"
  export LEAK_GUARD_STOPLIST="$W/stoplist.txt"
  "$W/ops/leak-guard/install-hooks.sh" >/dev/null
}

teardown() { rm -rf "$W"; }

# What a green full run leaves behind: the tree it ran on, in the stamp file.
stamp() { git -C "$1" rev-parse 'HEAD^{tree}' >>"$1/.git/spine-verified-trees"; }

# A second plugin, built like core but recording into its own files.
add_edge() {
  mkrepo "$W/edge"
  mkdir -p "$W/edge/.claude-plugin"
  printf '{\n  "name": "edge",\n  "version": "1.0.0"\n}\n' > "$W/edge/.claude-plugin/plugin.json"
  printf '#!/usr/bin/env bash\necho full > "%s"\n' "$W/edge-ran-full" > "$W/edge/verify.sh"
  printf '#!/usr/bin/env bash\necho "$*" > "%s"\n' "$W/edge-touched-args" > "$W/edge/touched.sh"
  chmod +x "$W/edge/verify.sh" "$W/edge/touched.sh"
  commit_all "$W/edge"; git -C "$W/edge" tag 1.0.0

  jq '.plugins += [{"name": "edge", "version": "1.0.0"}]' "$W/market/.claude-plugin/marketplace.json" > "$W/mp.json"
  mv "$W/mp.json" "$W/market/.claude-plugin/marketplace.json"
  commit_all "$W/market"

  jq '.checkouts.edge = {"path": "../edge", "verify": "./verify.sh", "verify_touched": "./touched.sh"}' \
    "$W/ops/repos.json" > "$W/repos.json"
  mv "$W/repos.json" "$W/ops/repos.json"
  echo "- the edge change" > "$W/ops/notes/edge-1.1.0.md"
  commit_all "$W/ops"
  "$W/ops/leak-guard/install-hooks.sh" >/dev/null
}

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

@test "a plugin that ships to Codex too is verified and committed with both manifests moved" {
  mkdir -p "$W/core/.codex-plugin"
  printf '{\n  "name": "core",\n  "version": "1.0.0"\n}\n' > "$W/core/.codex-plugin/plugin.json"
  printf '#!/usr/bin/env bash\n[ "$(jq -r .version .codex-plugin/plugin.json)" = "$(jq -r .version .claude-plugin/plugin.json)" ]\n' > "$W/core/verify.sh"
  commit_all "$W/core"

  run "$W/ops/scripts/release.sh" core=minor
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(jq -r .version "$W/core/.codex-plugin/plugin.json")" = "1.1.0" ]
  [ "$(git -C "$W/core" show --format= --name-only 1.1.0 | sort | tr '\n' ' ')" = ".claude-plugin/plugin.json .codex-plugin/plugin.json docs/driver.md " ]
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

@test "push publishes every unpushed release tag, not only the current one" {
  give_origins
  "$W/ops/scripts/release.sh" core=minor >/dev/null
  echo "- the next change" > "$W/ops/notes/core-1.2.0.md"
  commit_all "$W/ops"
  "$W/ops/scripts/release.sh" core=minor >/dev/null
  # Named like a version but not a release commit: still somebody's scratch.
  git -C "$W/core" tag 9.9.9 HEAD~1

  run "$W/ops/scripts/push.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  git -C "$W/core.git" rev-parse -q --verify refs/tags/1.1.0
  git -C "$W/core.git" rev-parse -q --verify refs/tags/1.2.0
  git -C "$W/market.git" rev-parse -q --verify refs/tags/1.1.0
  git -C "$W/market.git" rev-parse -q --verify refs/tags/1.2.0
  run git -C "$W/core.git" rev-parse -q --verify refs/tags/9.9.9
  [ "$status" -ne 0 ]
}

@test "a stamped tree runs only the tests of the files the release rewrites" {
  stamp "$W/core"
  run "$W/ops/scripts/release.sh" core=minor
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat "$TOUCHED_ARGS")" = ".claude-plugin/plugin.json docs/driver.md" ]
  [ ! -e "$RAN_FULL" ]
  [[ "$output" == *"core: tree "*" passed a full run — the release runs the tests that name its files"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"core: touched files verified at 1.1.0"* ]] || { echo "$output"; return 1; }
  git -C "$W/core" rev-parse -q --verify refs/tags/1.1.0
}

@test "an unstamped tree runs the full suite and says it takes minutes" {
  run "$W/ops/scripts/release.sh" core=minor
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -e "$RAN_FULL" ]
  [ ! -e "$TOUCHED_ARGS" ]
  [[ "$output" == *"core: no full run of tree "*" — the release runs the full suite"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"core: full suite (./verify.sh) — this takes minutes"* ]] || { echo "$output"; return 1; }
}

@test "a stamp of another tree runs the full suite" {
  echo 0000000000000000000000000000000000000000 >>"$W/core/.git/spine-verified-trees"
  run "$W/ops/scripts/release.sh" core=minor
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -e "$RAN_FULL" ]
  [ ! -e "$TOUCHED_ARGS" ]
  [[ "$output" == *"core: no full run of tree "* ]] || { echo "$output"; return 1; }
}

@test "a line that only starts with the tree is not a match" {
  printf '%sx\n' "$(git -C "$W/core" rev-parse 'HEAD^{tree}')" >>"$W/core/.git/spine-verified-trees"
  run "$W/ops/scripts/release.sh" core=minor
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -e "$RAN_FULL" ]
  [ ! -e "$TOUCHED_ARGS" ]
  [[ "$output" == *"core: no full run of tree "* ]] || { echo "$output"; return 1; }
}

@test "a stamped tree without verify_touched runs the full suite" {
  jq 'del(.checkouts.core.verify_touched)' "$W/ops/repos.json" > "$W/repos.json"
  mv "$W/repos.json" "$W/ops/repos.json"
  commit_all "$W/ops"
  stamp "$W/core"
  run "$W/ops/scripts/release.sh" core=minor
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -e "$RAN_FULL" ]
  [ ! -e "$TOUCHED_ARGS" ]
  [[ "$output" == *"core: tree "*" passed a full run, but no verify_touched is declared — the release runs the full suite"* ]] || { echo "$output"; return 1; }
}

@test "a failing touched run reverts every edit and tags nothing" {
  stamp "$W/core"
  core_head="$(git -C "$W/core" rev-parse HEAD)"
  market_head="$(git -C "$W/market" rev-parse HEAD)"
  TOUCHED_RC=1 run "$W/ops/scripts/release.sh" core=minor
  [ "$status" -ne 0 ]
  [ -e "$TOUCHED_ARGS" ]
  [ ! -e "$RAN_FULL" ]
  [ "$(git -C "$W/core" rev-parse HEAD)" = "$core_head" ]
  [ "$(git -C "$W/market" rev-parse HEAD)" = "$market_head" ]
  [ -z "$(git -C "$W/core" status --porcelain)" ]
  [ -z "$(git -C "$W/market" status --porcelain)" ]
  run git -C "$W/core" rev-parse -q --verify refs/tags/1.1.0
  [ "$status" -ne 0 ]
}

@test "a dry run shows the path and runs neither" {
  stamp "$W/core"
  run "$W/ops/scripts/release.sh" core=minor --dry-run
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"verified:"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"core: tree "*" passed a full run"* ]] || { echo "$output"; return 1; }
  [ ! -e "$TOUCHED_ARGS" ]
  [ ! -e "$RAN_FULL" ]
}

@test "two plugins in one release each take their own path" {
  add_edge
  stamp "$W/core"
  run "$W/ops/scripts/release.sh" core=minor edge=minor
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -e "$TOUCHED_ARGS" ]
  [ ! -e "$RAN_FULL" ]
  [ -e "$W/edge-ran-full" ]
  [ ! -e "$W/edge-touched-args" ]
  [[ "$output" == *"edge: no full run of tree "* ]] || { echo "$output"; return 1; }
  git -C "$W/edge" rev-parse -q --verify refs/tags/1.1.0
}
