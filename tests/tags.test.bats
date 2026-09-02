#!/usr/bin/env bats
# What the release reads off a checkout: which version is the highest so far, and
# whether anything has landed since. Both are answered from tags, and both are
# wrong in the same silent way if the sort is textual.

setup() {
  . "$BATS_TEST_DIRNAME/../scripts/lib.sh"
  REPO="$(mktemp -d)"
  git -C "$REPO" init --quiet
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name Test
  commit() { : > "$REPO/$1"; git -C "$REPO" add -A; git -C "$REPO" commit --quiet -m "$1"; }
}

teardown() { rm -rf "$REPO"; }

@test "latest_tag takes the highest version, not the newest tag" {
  commit a; git -C "$REPO" tag 1.2.0
  commit b; git -C "$REPO" tag 1.10.0
  commit c; git -C "$REPO" tag 1.9.0
  # 1.9.0 is both the newest and, as text, the largest. Neither makes it latest.
  [ "$(latest_tag "$REPO")" = "1.10.0" ]
}

@test "latest_tag ignores tags that are not versions" {
  commit a; git -C "$REPO" tag 1.2.0
  commit b; git -C "$REPO" tag release-candidate
  [ "$(latest_tag "$REPO")" = "1.2.0" ]
}

@test "latest_tag is empty in a repository with no version tag" {
  commit a
  [ -z "$(latest_tag "$REPO")" ]
}

@test "unreleased_count counts commits since the highest tag" {
  commit a; git -C "$REPO" tag 1.0.0
  [ "$(unreleased_count "$REPO")" -eq 0 ]
  commit b; commit c
  [ "$(unreleased_count "$REPO")" -eq 2 ]
}

@test "unreleased_count counts every commit when nothing is tagged" {
  commit a; commit b
  [ "$(unreleased_count "$REPO")" -eq 2 ]
}

@test "unreleased_count measures from the highest tag, not the most recent one" {
  commit a; git -C "$REPO" tag 1.10.0
  commit b; git -C "$REPO" tag 1.9.0
  # Counting from 1.9.0 would say 0; the highest tag is 1.10.0, one commit back.
  [ "$(unreleased_count "$REPO")" -eq 1 ]
}

@test "has_tag answers about the tag, not a branch of the same name" {
  commit a; git -C "$REPO" tag 1.0.0
  has_tag "$REPO" 1.0.0
  run has_tag "$REPO" 2.0.0
  [ "$status" -ne 0 ]
}
