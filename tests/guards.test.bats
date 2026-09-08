#!/usr/bin/env bats
# The gate every repository passes before a release touches it. It now guards
# spine-ops too, whose release notes are the tag's only description: a note left
# uncommitted here publishes a tag that explains nothing.

setup() {
  . "$BATS_TEST_DIRNAME/../scripts/lib.sh"
  REPO="$(mktemp -d)"
  git -C "$REPO" init --quiet -b main
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name Test
  : > "$REPO/a"; git -C "$REPO" add -A; git -C "$REPO" commit --quiet -m a
}

teardown() { rm -rf "$REPO" "${ORIGIN:-}"; }

# A remote the checkout can be measured against, one commit ahead of it.
give_origin_ahead() {
  ORIGIN="$(mktemp -d)"
  git -C "$ORIGIN" init --quiet --bare -b main
  git -C "$REPO" remote add origin "$ORIGIN"
  git -C "$REPO" push --quiet origin main
  local clone; clone="$(mktemp -d)"
  git -C "$clone" clone --quiet "$ORIGIN" c
  git -C "$clone/c" config user.email t@example.com
  git -C "$clone/c" config user.name Test
  : > "$clone/c/b"; git -C "$clone/c" add -A; git -C "$clone/c" commit --quiet -m b
  git -C "$clone/c" push --quiet origin main
  rm -rf "$clone"
  git -C "$REPO" fetch --quiet origin
}

@test "guard_release_ready passes a clean checkout on main" {
  run guard_release_ready spine-ops "$REPO"
  [ "$status" -eq 0 ]
}

@test "guard_release_ready refuses a checkout on another branch" {
  git -C "$REPO" checkout --quiet -b side
  run guard_release_ready spine-ops "$REPO"
  [ "$status" -ne 0 ]
  case "$output" in *"is on 'side'"*) ;; *) echo "$output"; return 1 ;; esac
}

@test "guard_release_ready refuses a checkout with uncommitted work" {
  : > "$REPO/note.md"
  run guard_release_ready spine-ops "$REPO"
  [ "$status" -ne 0 ]
  case "$output" in *"uncommitted changes"*) ;; *) echo "$output"; return 1 ;; esac
}

@test "guard_release_ready refuses a checkout behind its origin" {
  give_origin_ahead
  run guard_release_ready spine-ops "$REPO"
  [ "$status" -ne 0 ]
  case "$output" in *behind*) ;; *) echo "$output"; return 1 ;; esac
}
