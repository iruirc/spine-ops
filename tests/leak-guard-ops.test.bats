#!/usr/bin/env bats
# release.sh, push.sh and status.sh run leak-guard before anything moves: the
# hooks must be installed in every repo that reaches the public, and what is
# about to be released or pushed must scan clean. These run the real scripts
# against throwaway repositories laid out like the family; data is synthetic.

mkrepo() {
  mkdir -p "$1"
  git -C "$1" init --quiet -b main
  git -C "$1" config user.email t@example.com
  git -C "$1" config user.name Test
}

commit_all() { git -C "$1" add -A; git -C "$1" commit --quiet -m change; }

# A commit the hooks would stop: made with them switched off for this one call.
commit_unguarded() { git -C "$1" add -A; git -C "$1" -c core.hooksPath=/dev/null commit --quiet -m "${2:-change}"; }

setup() {
  W="$(mktemp -d)"
  W="$(cd "$W" && pwd -P)"
  export HOME="$W/home"
  mkdir -p "$HOME"
  export VERIFIED_AT="$W/verified-at"

  printf 'word Gizmo\n' > "$W/stoplist.txt"
  export LEAK_GUARD_STOPLIST="$W/stoplist.txt"

  # gh must never reach the network from a test.
  mkdir -p "$W/bin"
  printf '#!/bin/sh\nexit 1\n' > "$W/bin/gh"
  chmod +x "$W/bin/gh"
  export PATH="$W/bin:$PATH"

  mkrepo "$W/core"
  mkdir -p "$W/core/.claude-plugin"
  printf '{\n  "name": "core",\n  "version": "1.0.0"\n}\n' > "$W/core/.claude-plugin/plugin.json"
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
    "core": { "path": "../core" }
  }
}
JSON
  echo "- the change" > "$W/ops/notes/core-1.1.0.md"
  mkrepo "$W/ops"; commit_all "$W/ops"

  for r in core market ops; do
    git init --quiet --bare -b main "$W/$r.git"
    git -C "$W/$r" remote add origin "$W/$r.git"
    git -C "$W/$r" push --quiet origin main
    git -C "$W/$r" push --quiet origin --tags
  done
  git -C "$W/ops" push --quiet origin main
}

teardown() { rm -rf "$W"; }

install_hooks() { "$W/ops/leak-guard/install-hooks.sh" >/dev/null; }

head_of() { git -C "$W/$1.git" rev-parse main; }

@test "release stops in guards on notes with Gizmo, trees untouched" {
  install_hooks
  echo "- a Gizmo fix" > "$W/ops/notes/core-1.1.0.md"
  commit_unguarded "$W/ops"
  core_head="$(git -C "$W/core" rev-parse HEAD)"
  market_head="$(git -C "$W/market" rev-parse HEAD)"

  run "$W/ops/scripts/release.sh" core=minor
  [ "$status" -ne 0 ]
  [[ "$output" == *"notes/core-1.1.0.md"*"message:1 stoplist#1"* ]] || { echo "$output"; return 1; }
  [ "$(git -C "$W/core" rev-parse HEAD)" = "$core_head" ]
  [ "$(git -C "$W/market" rev-parse HEAD)" = "$market_head" ]
  [ -z "$(git -C "$W/core" status --porcelain)" ]
  [ -z "$(git -C "$W/market" status --porcelain)" ]
  [ -z "$(git -C "$W/ops" status --porcelain)" ]
  run git -C "$W/core" rev-parse -q --verify refs/tags/1.1.0
  [ "$status" -ne 0 ]
}

@test "release checks the notes as the commit-msg hook does: an allow for the notes path does not help" {
  install_hooks
  printf 'word Gizmo\nallow Gizmo ops:notes/core-1.1.0.md\n' > "$W/stoplist.txt"
  echo "- a Gizmo fix" > "$W/ops/notes/core-1.1.0.md"
  commit_unguarded "$W/ops"
  core_head="$(git -C "$W/core" rev-parse HEAD)"

  run "$W/ops/scripts/release.sh" core=minor
  [ "$status" -ne 0 ]
  [[ "$output" == *"notes/core-1.1.0.md"*"message:1 stoplist#1"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"do not pass leak-guard"* ]] || { echo "$output"; return 1; }
  [ "$(git -C "$W/core" rev-parse HEAD)" = "$core_head" ]
  run git -C "$W/core" rev-parse -q --verify refs/tags/1.1.0
  [ "$status" -ne 0 ]
}

@test "release --dry-run also scans the notes" {
  install_hooks
  echo "- a Gizmo fix" > "$W/ops/notes/core-1.1.0.md"
  commit_unguarded "$W/ops"

  run "$W/ops/scripts/release.sh" core=minor --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"notes/core-1.1.0.md"*"message:1 stoplist#1"* ]] || { echo "$output"; return 1; }
}

@test "release passes clean notes with the hooks installed" {
  install_hooks
  run "$W/ops/scripts/release.sh" core=minor
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  git -C "$W/core" rev-parse -q --verify refs/tags/1.1.0
}

@test "release refuses when a participating repo has no leak-guard hooks" {
  install_hooks
  git -C "$W/core" config --local --unset core.hooksPath

  run "$W/ops/scripts/release.sh" core=minor
  [ "$status" -ne 0 ]
  [[ "$output" == *"core has no leak-guard hooks"*"install-hooks.sh"* ]] || { echo "$output"; return 1; }
  run git -C "$W/core" rev-parse -q --verify refs/tags/1.1.0
  [ "$status" -ne 0 ]
}

@test "release refuses when the marketplace or spine-ops has no hooks, also under --dry-run" {
  install_hooks
  git -C "$W/market" config --local --unset core.hooksPath
  run "$W/ops/scripts/release.sh" core=minor --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"market has no leak-guard hooks"* ]] || { echo "$output"; return 1; }

  install_hooks
  git -C "$W/ops" config --local --unset core.hooksPath
  run "$W/ops/scripts/release.sh" core=minor --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"ops has no leak-guard hooks"* ]] || { echo "$output"; return 1; }
}

@test "push sends nothing when one repo has a Gizmo commit" {
  install_hooks
  echo clean > "$W/core/a.txt"; commit_all "$W/core"
  echo "Gizmo" > "$W/market/b.txt"; commit_unguarded "$W/market"
  core_origin="$(head_of core)"; market_origin="$(head_of market)"

  run "$W/ops/scripts/push.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"stoplist#1"* ]] || { echo "$output"; return 1; }
  [ "$(head_of core)" = "$core_origin" ]
  [ "$(head_of market)" = "$market_origin" ]
}

@test "push --dry-run also refuses on a Gizmo commit" {
  install_hooks
  echo "Gizmo" > "$W/core/a.txt"; commit_unguarded "$W/core"

  run "$W/ops/scripts/push.sh" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"stoplist#1"* ]] || { echo "$output"; return 1; }
}

@test "push scans a new branch that origin has not seen" {
  install_hooks
  git -C "$W/core" branch -m work
  echo "Gizmo" > "$W/core/a.txt"; commit_unguarded "$W/core"

  run "$W/ops/scripts/push.sh" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"stoplist#1"* ]] || { echo "$output"; return 1; }
}

@test "push scans pending tags" {
  install_hooks
  echo clean > "$W/core/a.txt"; commit_all "$W/core"
  git -C "$W/core" commit --quiet --allow-empty -m "chore: release 1.1.0"
  git -C "$W/core" tag -a 1.1.0 -m "the Gizmo release"
  core_origin="$(head_of core)"

  run "$W/ops/scripts/push.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"tag 1.1.0 message:1"*"stoplist#1"* ]] || { echo "$output"; return 1; }
  [ "$(head_of core)" = "$core_origin" ]
  run git -C "$W/core.git" rev-parse -q --verify refs/tags/1.1.0
  [ "$status" -ne 0 ]
}

@test "push refuses when hooks are not installed" {
  install_hooks
  git -C "$W/market" config --local --unset core.hooksPath
  echo clean > "$W/core/a.txt"; commit_all "$W/core"
  core_origin="$(head_of core)"

  run "$W/ops/scripts/push.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"market has no leak-guard hooks"* ]] || { echo "$output"; return 1; }
  [ "$(head_of core)" = "$core_origin" ]
}

@test "push sends clean commits when everything passes" {
  install_hooks
  echo clean > "$W/core/a.txt"; commit_all "$W/core"

  run "$W/ops/scripts/push.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(head_of core)" = "$(git -C "$W/core" rev-parse HEAD)" ]
}

@test "status shows the leak-guard section and still exits 0 when it is red" {
  run "$W/ops/scripts/status.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"leak-guard:"* ]] || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -qE '^  +core +missing'
  install_hooks
  run "$W/ops/scripts/status.sh"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qE '^  +core +ok'
}

@test "release without a stoplist fails closed, nothing is tagged" {
  install_hooks
  core_head="$(git -C "$W/core" rev-parse HEAD)"

  LEAK_GUARD_STOPLIST=/nonexistent run "$W/ops/scripts/release.sh" core=minor
  [ "$status" -ne 0 ]
  [[ "$output" == *"no stoplist"* ]] || { echo "$output"; return 1; }
  [ "$(git -C "$W/core" rev-parse HEAD)" = "$core_head" ]
  [ -z "$(git -C "$W/core" status --porcelain)" ]
  run git -C "$W/core" rev-parse -q --verify refs/tags/1.1.0
  [ "$status" -ne 0 ]
  run git -C "$W/market" rev-parse -q --verify refs/tags/1.1.0
  [ "$status" -ne 0 ]
}

@test "push without a stoplist fails closed, nothing is pushed" {
  install_hooks
  echo clean > "$W/core/a.txt"; commit_all "$W/core"
  core_origin="$(head_of core)"

  LEAK_GUARD_STOPLIST=/nonexistent run "$W/ops/scripts/push.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no stoplist"* ]] || { echo "$output"; return 1; }
  [ "$(head_of core)" = "$core_origin" ]
}
