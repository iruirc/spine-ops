#!/usr/bin/env bats
# scan.sh turns what git is about to publish into the stream match.pl reads:
# staged changes, commit and tag messages, ranges, single files, the tree and
# the whole history. These run it against throwaway repositories. Data here is
# synthetic on purpose; the real stoplist never leaves the owner's machine.

# Strings the public patterns catch are built here, never written out, so this
# file passes the scan it tests.
U=/Users

setup() {
  SCAN="$BATS_TEST_DIRNAME/../leak-guard/scan.sh"
  export LEAK_GUARD_STOPLIST="$BATS_TEST_TMPDIR/stoplist"
  printf 'word Gizmo\nallow Gizmo spine-x:tests/ok.md\n' > "$LEAK_GUARD_STOPLIST"
  R="$BATS_TEST_TMPDIR/spine-x"
  mkrepo "$R"
  printf 'base\n' > "$R/a.md"
  commit_all "$R" base
  BASE="$(git -C "$R" rev-parse --short HEAD)"
  cd "$R"
}

mkrepo() {
  mkdir -p "$1"
  git -C "$1" init --quiet -b main
  git -C "$1" config user.email t@example.com
  git -C "$1" config user.name Test
}

commit_all() { git -C "$1" add -A; git -C "$1" commit --quiet -m "$2"; }
head7() { git rev-parse --short HEAD; }
# Merged streams: a leak through stderr counts as a leak.
scan() { bash "$SCAN" "$@" 2>&1; }
has() { printf '%s\n' "$output" | grep -qxF -- "$1"; }
lacks() { ! printf '%s\n' "$output" | grep -qF -- "$1"; }

@test "--staged: an added line with Gizmo fails, a removed one passes" {
  printf 'old Gizmo\n' > old.md
  commit_all . old
  rm old.md
  git add -A
  run scan --staged
  [ "$status" -eq 0 ]
  lacks Gizmo

  printf 'base\na Gizmo\n' > a.md
  git add -A
  run scan --staged
  [ "$status" -eq 1 ]
  has "a.md:2 stoplist#1 Gizmo"
  lacks old.md
}

@test "--staged: a renamed file whose new path has Gizmo fails" {
  mkdir docs
  printf 'hello\n' > docs/plain.md
  commit_all . plain
  git mv docs/plain.md docs/Gizmo.md
  run scan --staged
  [ "$status" -eq 1 ]
  has "docs/Gizmo.md (path) stoplist#1 Gizmo"
}

@test "--staged: a binary file with Gizmo inside is skipped" {
  printf 'Gizmo\000\001\002\n' > blob.bin
  git add blob.bin
  run scan --staged
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "--staged: a path with a space and Cyrillic is reported as is" {
  mkdir docs
  printf 'a Gizmo\n' > 'docs/мой файл.md'
  git add -A
  run scan --staged
  [ "$status" -eq 1 ]
  has 'docs/мой файл.md:1 stoplist#1 Gizmo'
}

@test "--message: every line is checked, a # line too" {
  printf 'subject\n\nbody Gizmo\n# heading Gizmo\n' > "$BATS_TEST_TMPDIR/msg"
  run scan --message "$BATS_TEST_TMPDIR/msg"
  [ "$status" -eq 1 ]
  has "message:3 stoplist#1 Gizmo"
  has "message:4 stoplist#1 Gizmo"
}

@test "--message: the scissors line and the lines after it are checked, git keeps them" {
  printf 'subject\n# ------------------------ >8 ------------------------\ndiff Gizmo\n' > "$BATS_TEST_TMPDIR/msg"
  run scan --message "$BATS_TEST_TMPDIR/msg"
  [ "$status" -eq 1 ]
  has "message:3 stoplist#1 Gizmo"
}

@test "--range: a line added then removed inside the range still fails" {
  printf 'Gizmo\nbase\n' > a.md
  commit_all . add
  c1="$(head7)"
  printf 'base\n' > a.md
  commit_all . remove
  run scan --range "$BASE..HEAD"
  [ "$status" -eq 1 ]
  has "commit $c1 a.md:1 stoplist#1 Gizmo"
  [ "${lines[0]}" = "commit $c1 a.md:1 stoplist#1 Gizmo" ]
}

@test "--range: a merge commit is checked by message only" {
  git checkout --quiet -b side
  printf 'Gizmo\n' > s.md
  commit_all . side
  side="$(head7)"
  git checkout --quiet main
  printf 'main\n' > m.md
  commit_all . main
  git merge --quiet --no-ff -m 'merge Gizmo' side
  merge="$(head7)"
  run scan --range "$BASE..HEAD"
  [ "$status" -eq 1 ]
  has "commit $side s.md:1 stoplist#1 Gizmo"
  has "commit $merge message:1 stoplist#1 Gizmo"
  [ "${#lines[@]}" -eq 3 ]
}

@test "--commits-not-on: only commits absent from the remote are checked" {
  git init --quiet --bare "$BATS_TEST_TMPDIR/remote.git"
  git remote add origin "$BATS_TEST_TMPDIR/remote.git"
  printf 'Gizmo\n' > pushed.md
  commit_all . pushed
  git push --quiet origin main
  printf 'clean\n' > b.md
  commit_all . clean
  run scan --commits-not-on origin HEAD
  [ "$status" -eq 0 ]

  printf 'Gizmo\n' > c.md
  commit_all . leak
  c="$(head7)"
  run scan --commits-not-on origin HEAD
  [ "$status" -eq 1 ]
  has "commit $c c.md:1 stoplist#1 Gizmo"
  lacks pushed.md
}

@test "--tag: an annotated tag message with Gizmo fails, a lightweight tag passes" {
  git tag -a v1 -m 'release Gizmo'
  run scan --tag v1
  [ "$status" -eq 1 ]
  has "tag v1 message:1 stoplist#1 Gizmo"

  git tag v2
  run scan --tag v2
  [ "$status" -eq 0 ]

  run scan --tag nope
  [ "$status" -eq 2 ]
}

@test "--tag: an id that is a tree or a blob is an error, not a clean pass" {
  run scan --tag "$(git rev-parse HEAD^{tree})"
  [ "$status" -eq 2 ]
  run scan --tag "$(git rev-parse HEAD:a.md)"
  [ "$status" -eq 2 ]
  git tag tree-tag "$(git rev-parse HEAD^{tree})"
  run scan --tag tree-tag
  [ "$status" -eq 2 ]
  git tag blob-tag "$(git rev-parse HEAD:a.md)"
  run scan --tag blob-tag
  [ "$status" -eq 2 ]
}

@test "--tag: an annotated tag that peels to a tree is an error" {
  git tag -a -m 'on a tree' tree-ann "$(git rev-parse HEAD^{tree})"
  run scan --tag tree-ann
  [ "$status" -eq 2 ]
  run scan --tag "$(git rev-parse tree-ann)"
  [ "$status" -eq 2 ]
}

@test "--tag: the error for a tree id under --redact names no value" {
  run scan --redact --tag "$(git rev-parse HEAD^{tree})"
  [ "$status" -eq 2 ]
  lacks "$(git rev-parse HEAD^{tree})"
}

@test "--tag: a tag on an unpushed commit with Gizmo in its patch fails" {
  printf 'Gizmo\n' > c.md
  commit_all . leak
  c="$(head7)"
  git tag -a v3 -m 'release'
  run scan --tag v3
  [ "$status" -eq 1 ]
  has "commit $c c.md:1 stoplist#1 Gizmo"
}

@test "--tag --remote: only commits the named remote lacks are scanned" {
  git init --quiet --bare -b main "$BATS_TEST_TMPDIR/origin.git"
  git init --quiet --bare -b main "$BATS_TEST_TMPDIR/other.git"
  git remote add origin "$BATS_TEST_TMPDIR/origin.git"
  git remote add other "$BATS_TEST_TMPDIR/other.git"
  git push --quiet origin main
  printf 'Gizmo\n' > c.md
  commit_all . leak
  c="$(head7)"
  git push --quiet other main
  git tag -a v4 -m 'release'

  run scan --tag v4
  [ "$status" -eq 0 ]
  run scan --tag v4 --remote other
  [ "$status" -eq 0 ]
  run scan --tag v4 --remote origin
  [ "$status" -eq 1 ]
  has "commit $c c.md:1 stoplist#1 Gizmo"
  run scan --remote origin --tag v4
  [ "$status" -eq 1 ]
}

@test "--remote is only for --tag" {
  run scan --staged --remote origin
  [ "$status" -eq 2 ]
  run scan --tag
  [ "$status" -eq 2 ]
  git tag v5
  run scan --tag v5 --remote
  [ "$status" -eq 2 ]
}

@test "--tag: a full object id of an annotated tag is read like its name" {
  git tag -a v6 -m 'release Gizmo'
  run scan --tag "$(git rev-parse v6)"
  [ "$status" -eq 1 ]
  [[ "$output" == *"message:1 stoplist#1 Gizmo"* ]] || false
}

@test "--file: whole file checked, loc is path:line" {
  mkdir sub
  printf 'one\ntwo Gizmo\n' > sub/x.md
  cd sub
  run scan --file x.md
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = "sub/x.md:2 stoplist#1 Gizmo" ]
  [ "${#lines[@]}" -eq 2 ]

  run scan --file missing.md
  [ "$status" -eq 2 ]
}

@test "--file: a non-UTF-8 text file is checked, a file with a NUL is skipped" {
  printf '\300\301 Gizmo\n' > latin.md
  run scan --file latin.md
  [ "$status" -eq 1 ]
  has "latin.md:1 stoplist#1 Gizmo"

  printf 'Gizmo\000x\n' > blob.bin
  run scan --file blob.bin
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "--tree: an old file catches a newly added record; allow file passes" {
  mkdir docs tests
  printf 'Gizmo\n' > docs/old.md
  printf 'Gizmo\n' > tests/ok.md
  printf 'word Other\n' > "$LEAK_GUARD_STOPLIST"
  commit_all . old
  run scan --tree
  [ "$status" -eq 0 ]

  printf 'word Gizmo\nallow Gizmo spine-x:tests/ok.md\n' > "$LEAK_GUARD_STOPLIST"
  run scan --tree
  [ "$status" -eq 1 ]
  has "docs/old.md:1 stoplist#1 Gizmo"
  lacks tests/ok.md
}

@test "--tree: a tracked file name is checked; allow passes it" {
  mkdir docs
  printf 'clean\n' > docs/Gizmo.md
  commit_all . name
  run scan --tree
  [ "$status" -eq 1 ]
  has "docs/Gizmo.md (path) stoplist#1 Gizmo"

  printf 'allow Gizmo spine-x:docs/Gizmo.md\n' >> "$LEAK_GUARD_STOPLIST"
  run scan --tree
  [ "$status" -eq 0 ]
}

@test "--tree: a path with a TAB stays whole" {
  printf 'a Gizmo\n' > "$(printf 'x\ty.md')"
  commit_all . tab
  run scan --tree
  [ "$status" -eq 1 ]
  has "x y.md:1 stoplist#1 Gizmo"
  [ "${#lines[@]}" -eq 2 ]
}

@test "--history: a commit on a side branch is checked" {
  git checkout --quiet -b side
  printf 'Gizmo\n' > s.md
  commit_all . side
  side="$(head7)"
  git checkout --quiet main
  git tag -a t1 -m 'tag Gizmo'
  run scan --history
  [ "$status" -eq 1 ]
  has "commit $side s.md:1 stoplist#1 Gizmo"
  has "tag t1 message:1 stoplist#1 Gizmo"
}

@test "repo name comes from origin, else the toplevel folder" {
  mkdir tests
  printf 'Gizmo\n' > tests/ok.md
  git add -A
  run scan --staged
  [ "$status" -eq 0 ]

  W="$BATS_TEST_TMPDIR/wt-1"
  mkrepo "$W"
  mkdir "$W/tests"
  printf 'Gizmo\n' > "$W/tests/ok.md"
  git -C "$W" add -A
  cd "$W"
  run scan --staged
  [ "$status" -eq 1 ]
  has "tests/ok.md:1 stoplist#1 Gizmo"

  git remote add origin 'git@x:o/spine-x.git'
  run scan --staged
  [ "$status" -eq 0 ]
}

# A copy of leak-guard laid out like the family, so the default stoplist path
# points into the test's own folder and never at the owner's real one.
copy_guard() {
  G="$BATS_TEST_TMPDIR/fam/spine-ops/leak-guard"
  mkdir -p "$G"
  cp "$BATS_TEST_DIRNAME/../leak-guard/scan.sh" "$BATS_TEST_DIRNAME/../leak-guard/match.pl" \
    "$BATS_TEST_DIRNAME/../leak-guard/patterns.txt" "$G/"
  SCAN="$G/scan.sh"
  unset LEAK_GUARD_STOPLIST
}

@test "no stoplist: exit 2 naming the expected path and LEAK_GUARD_STOPLIST" {
  copy_guard
  printf 'clean\n' > b.md
  git add -A
  run scan --staged
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -qF "$G/../../spine-notes/leak-guard/stoplist.txt"
  printf '%s\n' "$output" | grep -qF LEAK_GUARD_STOPLIST

  export LEAK_GUARD_STOPLIST="$BATS_TEST_TMPDIR/none"
  run scan --staged
  [ "$status" -eq 2 ]
  run scan --validate
  [ "$status" -eq 2 ]

  mkdir -p "$BATS_TEST_TMPDIR/fam/spine-notes/leak-guard"
  printf 'word Gizmo\n' > "$BATS_TEST_TMPDIR/fam/spine-notes/leak-guard/stoplist.txt"
  unset LEAK_GUARD_STOPLIST
  run scan --staged
  [ "$status" -eq 0 ]
}

@test "--patterns-only without a stoplist: a personal path fails, Gizmo passes" {
  copy_guard
  printf "see $U/zed/x\na Gizmo\n" > b.md
  git add -A
  run scan --patterns-only --staged
  [ "$status" -eq 1 ]
  has "b.md:1 patterns#6 $U/zed"
  [ "${#lines[@]}" -eq 2 ]
  lacks stoplist#
}

@test "--redact: no matched text on stdout or stderr" {
  mkdir docs
  printf "a Gizmo\nsee $U/zed/x\n" > docs/Gizmo.md
  git add -A
  run scan --redact --staged
  [ "$status" -eq 1 ]
  lacks Gizmo
  lacks zed
  has "<redacted path>:1 stoplist#1"
  has "<redacted path> stoplist#1"
}

@test "--redact: error messages carry no argument values" {
  run scan --redact --tag Gizmo-1
  [ "$status" -eq 2 ]
  lacks Gizmo
  run scan --redact --file Gizmo.md
  [ "$status" -eq 2 ]
  lacks Gizmo
  run scan --redact --range "Gizmo..HEAD"
  [ "$status" -eq 2 ]
  lacks Gizmo
  run scan --redact --Gizmo
  [ "$status" -eq 2 ]
  lacks Gizmo
}

@test "exit 1 without --redact ends with the hint" {
  printf 'a Gizmo\n' > b.md
  git add -A
  run scan --staged
  [ "$status" -eq 1 ]
  printf '%s\n' "${lines[${#lines[@]}-1]}" | grep -qF 'allow <value> spine-x:<path>'
}

@test "--validate passes a good stoplist; bad arguments exit 2" {
  run scan --validate
  [ "$status" -eq 0 ]
  run scan --bogus
  [ "$status" -eq 2 ]
  run scan
  [ "$status" -eq 2 ]
  run scan --help
  [ "$status" -eq 0 ]
}

@test "spine-ops's own tree is clean under the public patterns" {
  cd "$BATS_TEST_DIRNAME/.."
  run scan --patterns-only --tree
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -z "$output" ]
}
