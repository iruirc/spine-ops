#!/usr/bin/env bats
# A checkout keeps its instructions for agents in one file, AGENTS.md. CLAUDE.md
# only imports it, so there is nothing in it to drift away from AGENTS.md.

setup() {
  W="$(mktemp -d)"
  mkdir -p "$W/ops/scripts" "$W/repo"
  cp "$BATS_TEST_DIRNAME/../scripts/lib.sh" "$W/ops/scripts/lib.sh"
  echo '{}' > "$W/ops/repos.json"
  printf '# rules\n' > "$W/repo/AGENTS.md"
  printf '@AGENTS.md\n' > "$W/repo/CLAUDE.md"
  . "$W/ops/scripts/lib.sh"
}

teardown() { rm -rf "$W"; }

@test "a repository with AGENTS.md and a one-line CLAUDE.md passes" {
  run agents_md_errors "$W/repo"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -z "$output" ]
}

@test "CLAUDE.md without a trailing newline passes" {
  printf '@AGENTS.md' > "$W/repo/CLAUDE.md"

  run agents_md_errors "$W/repo"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -z "$output" ]
}

@test "a missing AGENTS.md is reported" {
  rm "$W/repo/AGENTS.md"

  run agents_md_errors "$W/repo"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no AGENTS.md"* ]] || { echo "$output"; return 1; }
}

@test "an empty AGENTS.md is reported" {
  : > "$W/repo/AGENTS.md"

  run agents_md_errors "$W/repo"
  [ "$status" -eq 1 ]
  [[ "$output" == *"AGENTS.md is empty"* ]] || { echo "$output"; return 1; }
}

@test "a CLAUDE.md with more than the import is reported" {
  printf '@AGENTS.md\nextra rules\n' > "$W/repo/CLAUDE.md"

  run agents_md_errors "$W/repo"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CLAUDE.md is not the one line @AGENTS.md"* ]] || { echo "$output"; return 1; }
}

@test "a missing CLAUDE.md is reported" {
  rm "$W/repo/CLAUDE.md"

  run agents_md_errors "$W/repo"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CLAUDE.md is not the one line @AGENTS.md"* ]] || { echo "$output"; return 1; }
}

@test "a CLAUDE.md that links to AGENTS.md is reported" {
  rm "$W/repo/CLAUDE.md"
  ( cd "$W/repo" && ln -sf AGENTS.md CLAUDE.md )

  run agents_md_errors "$W/repo"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CLAUDE.md is not the one line @AGENTS.md"* ]] || { echo "$output"; return 1; }
}

@test "a leftover .claude/CLAUDE.md is reported" {
  mkdir -p "$W/repo/.claude"
  printf 'old rules\n' > "$W/repo/.claude/CLAUDE.md"

  run agents_md_errors "$W/repo"
  [ "$status" -eq 1 ]
  [[ "$output" == *".claude/CLAUDE.md is still there"* ]] || { echo "$output"; return 1; }
}
