#!/usr/bin/env bats
# The three git hooks run scan.sh at the moment git is about to record or
# publish something. These drive real git against throwaway repositories with
# core.hooksPath pointing at leak-guard/hooks. Data here is synthetic on
# purpose; the real stoplist never leaves the owner's machine.

setup() {
  HOOKS="$BATS_TEST_DIRNAME/../leak-guard/hooks"
  export LEAK_GUARD_STOPLIST="$BATS_TEST_TMPDIR/stoplist"
  printf 'word Gizmo\n' > "$LEAK_GUARD_STOPLIST"
  ORIGIN="$BATS_TEST_TMPDIR/origin.git"
  git init --quiet --bare -b main "$ORIGIN"
  R="$BATS_TEST_TMPDIR/spine-x"
  mkdir -p "$R"
  git -C "$R" init --quiet -b main
  git -C "$R" config user.email t@example.com
  git -C "$R" config user.name Test
  git -C "$R" config core.hooksPath "$HOOKS"
  git -C "$R" remote add origin "$ORIGIN"
  cd "$R"
  printf 'base\n' > a.md
  git add -A
  git commit --quiet -m base
  git push --quiet origin main
}

@test "the three hooks exist and are executable" {
  for h in pre-commit commit-msg pre-push; do
    [ -x "$HOOKS/$h" ]
  done
}

@test "pre-commit stops a staged Gizmo line" {
  printf 'base\nuses Gizmo here\n' > a.md
  git add -A
  run git commit -m "clean subject"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF 'a.md:2'
  [ "$(git rev-list --count HEAD)" -eq 1 ]
}

@test "commit-msg stops a Gizmo message body" {
  printf 'more\n' >> a.md
  git add -A
  run git commit -m "subject" -m "body mentions Gizmo"
  [ "$status" -ne 0 ]
  [ "$(git rev-list --count HEAD)" -eq 1 ]
}

@test "pre-push stops a commit that added and then removed Gizmo" {
  git -c core.hooksPath=/dev/null commit --quiet --allow-empty -m "start"
  printf 'leak Gizmo\n' > b.md
  git add -A
  git -c core.hooksPath=/dev/null commit --quiet -m "add"
  git rm --quiet b.md
  git -c core.hooksPath=/dev/null commit --quiet -m "remove"
  run git push origin main
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF 'b.md:1'
  [ "$(git -C "$ORIGIN" rev-list --count main)" -eq 1 ]
}

@test "pre-push stops an annotated tag whose message has Gizmo" {
  git tag -a v1 -m "release for Gizmo"
  run git push origin v1
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF 'tag v1 message:1'
  [ -z "$(git -C "$ORIGIN" tag -l)" ]
}

@test "pre-push stops an annotated tag object pushed by sha to a tag ref" {
  git tag -a v1 -m "release for Gizmo"
  run git push origin "$(git rev-parse v1)":refs/tags/x
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF 'message:1'
  [ -z "$(git -C "$ORIGIN" tag -l)" ]
}

@test "pre-push stops a tree sha pushed to a tag ref" {
  run git push origin "$(git rev-parse HEAD^{tree})":refs/tags/x
  [ "$status" -ne 0 ]
  [ -z "$(git -C "$ORIGIN" tag -l)" ]
}

@test "pre-push stops a tag pushed under another name" {
  git tag -a v1 -m "release for Gizmo"
  run git push origin refs/tags/v1:refs/tags/y
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF 'message:1'
  [ -z "$(git -C "$ORIGIN" tag -l)" ]
}

@test "pre-push stops a commit pushed by sha to a tag ref" {
  printf 'leak Gizmo\n' > c.md
  git add -A
  git -c core.hooksPath=/dev/null commit --quiet -m "work"
  run git push origin HEAD:refs/tags/z
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF 'c.md:1'
  [ -z "$(git -C "$ORIGIN" tag -l)" ]
}

@test "pre-push scans a tag against the pushed remote, not against every remote" {
  OTHER="$BATS_TEST_TMPDIR/other.git"
  git init --quiet --bare -b main "$OTHER"
  git remote add other "$OTHER"
  printf 'leak Gizmo\n' > c.md
  git add -A
  git -c core.hooksPath=/dev/null commit --quiet -m "work"
  git -c core.hooksPath=/dev/null push --quiet other main
  git tag -a v1 -m "clean release"
  run git push origin v1
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF 'c.md:1'
  [ -z "$(git -C "$ORIGIN" tag -l)" ]
}

@test "pre-push checks a new branch with no upstream against origin" {
  git checkout --quiet -b topic
  printf 'leak Gizmo\n' > c.md
  git add -A
  git -c core.hooksPath=/dev/null commit --quiet -m "topic work"
  run git push origin topic
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF 'c.md:1'
  ! git -C "$ORIGIN" rev-parse --verify --quiet refs/heads/topic
}

@test "pre-push checks every pushed ref, not just the first" {
  git checkout --quiet -b clean-branch
  printf 'fine\n' > d.md
  git add -A
  git commit --quiet -m "clean work"
  git checkout --quiet main
  git checkout --quiet -b dirty-branch
  printf 'leak Gizmo\n' > e.md
  git add -A
  git -c core.hooksPath=/dev/null commit --quiet -m "dirty work"
  run git push origin clean-branch dirty-branch
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF 'e.md:1'
}

@test "pre-push lets a branch deletion through" {
  git branch topic
  git push --quiet origin topic
  run git push origin --delete topic
  [ "$status" -eq 0 ]
  ! git -C "$ORIGIN" rev-parse --verify --quiet refs/heads/topic
}

@test "a clean commit and push pass all three hooks" {
  printf 'more\n' >> a.md
  git add -A
  run git commit -m "clean subject" -m "clean body"
  [ "$status" -eq 0 ]
  git tag -a v1 -m "clean release"
  run git push origin main v1
  [ "$status" -eq 0 ]
  [ "$(git -C "$ORIGIN" rev-list --count main)" -eq 2 ]
  [ -n "$(git -C "$ORIGIN" tag -l)" ]
}

@test "a hook reached through a symlink still finds scan.sh" {
  mkdir "$BATS_TEST_TMPDIR/linked"
  ln -s "$HOOKS/pre-commit" "$BATS_TEST_TMPDIR/linked/pre-commit"
  git config core.hooksPath "$BATS_TEST_TMPDIR/linked"
  printf 'leak Gizmo\n' > a.md
  git add -A
  run git commit -m "x"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF 'a.md:1'
}

@test "a missing stoplist makes the hook fail, not pass" {
  export LEAK_GUARD_STOPLIST="$BATS_TEST_TMPDIR/absent"
  printf 'more\n' >> a.md
  git add -A
  run git commit -m "clean"
  [ "$status" -ne 0 ]
  [ "$(git rev-list --count HEAD)" -eq 1 ]
}
