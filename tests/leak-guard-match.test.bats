#!/usr/bin/env bats
# match.pl is the pure core of leak-guard: a TAB-separated stream in, one line
# per hit out. Data here is synthetic on purpose; the real stoplist never
# leaves the owner's machine.

# Strings the public patterns catch are built here, never written out, so this
# file passes the scan it tests.
U=/Users
H=/home
V=/Volumes
BS='\'

setup() {
  MATCH="$BATS_TEST_DIRNAME/../leak-guard/match.pl"
  PATTERNS="$BATS_TEST_DIRNAME/../leak-guard/patterns.txt"
  SL="$BATS_TEST_TMPDIR/stoplist"
  IN="$BATS_TEST_TMPDIR/in"
  cat > "$SL" <<'LIST'
word Gizmo
ci gizmo corp
regex \bZORB-[0-9]{3,}\b
regex com\.gizmo\.
allow Gizmo spine-x:tests/ok.md
LIST
}

feed() { printf '%s\t%s\t%s\n' "$@"; }
m() { perl "$MATCH" --patterns "$PATTERNS" --stoplist "$SL" --repo spine-x "$@"; }
# Merged streams: a leak through stderr counts as a leak.
mr() { m "$@" 2>&1; }
validate() { perl "$MATCH" --validate --stoplist "$SL" 2>&1; }

@test "word: Gizmo matches whole words, also next to Cyrillic" {
  {
    feed a.md:1 a.md 'a Gizmo here'
    feed b.md:2 b.md 'Gizmo.swift'
    feed c.md:3 c.md 'в Gizmoе'
  } > "$IN"
  run m < "$IN"
  [ "$status" -eq 1 ]
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]}" = "a.md:1 stoplist#1 Gizmo" ]
  [ "${lines[1]}" = "b.md:2 stoplist#1 Gizmo" ]
  [ "${lines[2]}" = "c.md:3 stoplist#1 Gizmo" ]
}

@test "word: Gizmo leaves Ungizmoed, Gizmos, GizmoKit, gizmo" {
  feed a.md:1 a.md 'Ungizmoed Gizmos GizmoKit gizmo' > "$IN"
  run m < "$IN"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ci: gizmo corp matches GIZMO Corp" {
  feed a.md:1 a.md 'by GIZMO Corp today' > "$IN"
  run m < "$IN"
  [ "$status" -eq 1 ]
  [ "$output" = "a.md:1 stoplist#2 GIZMO Corp" ]
}

@test "regex: ZORB-123 and com.gizmo.app match" {
  feed a.md:1 a.md 'see ZORB-123' > "$IN"
  feed a.md:2 a.md 'id com.gizmo.app' >> "$IN"
  run m < "$IN"
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = "a.md:1 stoplist#3 ZORB-123" ]
  [ "${lines[1]}" = "a.md:2 stoplist#4 com.gizmo." ]
}

@test "allow: Gizmo passes in tests/ok.md of spine-x only" {
  feed a.md:1 tests/ok.md 'a Gizmo here' > "$IN"
  run m < "$IN"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  feed a.md:1 tests/other.md 'a Gizmo here' > "$IN"
  run m < "$IN"
  [ "$status" -eq 1 ]
  [[ "$output" == "a.md:1 stoplist#1 Gizmo" ]] || false

  feed a.md:1 tests/ok.md 'a Gizmo here' > "$IN"
  run perl "$MATCH" --patterns "$PATTERNS" --stoplist "$SL" --repo spine-y < "$IN"
  [ "$status" -eq 1 ]
  [[ "$output" == "a.md:1 stoplist#1 Gizmo" ]] || false
}

@test "patterns: a user, a volume, a home and a Windows path with a personal name are caught" {
  {
    feed a:1 a "$U/zed/x"
    feed a:2 a "$V/Disk/x"
    feed a:3 a "$H/zed/x"
    feed a:4 a "C:${BS}Users${BS}zed${BS}x"
    feed a:5 a "srC:${BS}Users${BS}zed${BS}x"
  } > "$IN"
  run m < "$IN"
  [ "$status" -eq 1 ]
  [ "${#lines[@]}" -eq 4 ]
  [[ "${lines[0]}" == "a:1 patterns#"*" $U/zed" ]] || false
  [[ "${lines[1]}" == "a:2 patterns#"*" $V/Disk" ]] || false
  [[ "${lines[2]}" == "a:3 patterns#"*" $H/zed" ]] || false
  [[ "${lines[3]}" == "a:4 patterns#"*" C:${BS}Users${BS}zed" ]] || false
}

@test "patterns: /Users/foo/x, /Users/u/.claude, /Users/Shared/x, /Users/<you>/x, /Users/\$USER/x pass" {
  {
    feed a:1 a '/Users/foo/x'
    feed a:2 a '/Users/u/.claude'
    feed a:3 a '/Users/Shared/x'
    feed a:4 a '/Users/<you>/x'
    feed a:5 a '/Users/$USER/x'
  } > "$IN"
  run m < "$IN"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "patterns: grep '/Volumes/|/Users/' and \$TMPDIR/home/work pass" {
  {
    feed a:1 a "grep '/Volumes/|/Users/' file"
    feed a:2 a '$TMPDIR/home/work'
  } > "$IN"
  run m < "$IN"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "patterns: file URLs and the macOS firmlink form are caught" {
  {
    feed a:1 a "file://$U/zed/x"
    feed a:2 a "file://$V/Disk/x"
    feed a:3 a "/System$V/Data$U/zed/x"
    feed a:4 a "file://$H/zed/x"
    feed a:5 a "open file://$U/zed/x now"
  } > "$IN"
  run m < "$IN"
  [ "$status" -eq 1 ]
  [[ "${lines[0]}" == "a:1 patterns#"*" $U/zed" ]] || false
  [[ "${lines[1]}" == "a:2 patterns#"*" $V/Disk" ]] || false
  [[ "${lines[2]}" == "a:3 patterns#"*" $U/zed" ]] || false
  [[ "${lines[3]}" == "a:4 patterns#"*" $H/zed" ]] || false
  [[ "${lines[4]}" == "a:5 patterns#"*" $U/zed" ]] || false
  [ "${#lines[@]}" -eq 5 ]
}

@test "patterns: file URL and firmlink placeholders still pass" {
  {
    feed a:1 a "file://$U/foo/x"
    feed a:2 a "file://$U/<you>/x"
    feed a:3 a "/System$V/Data$U/foo/x"
    feed a:4 a "/System$V/Data"
  } > "$IN"
  run m < "$IN"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "patterns: a Cyrillic letter right before the path does not hide it" {
  {
    feed a:1 a "в$U/zed/x"
    feed a:2 a "на$V/Disk/x"
    feed a:3 a "из$H/zed/x"
  } > "$IN"
  run m < "$IN"
  [ "$status" -eq 1 ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "patterns: a path inside a longer path or after a word still passes" {
  {
    feed a:1 a "/tmp$U/x"
    feed a:2 a "src$U/zed/x"
    feed a:3 a "\$HOME$H/zed"
  } > "$IN"
  run m < "$IN"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "patterns: a real name that starts with a placeholder is caught" {
  {
    feed a:1 a "$U/alice-smith/x"
    feed a:2 a "$U/bob.jones/x"
    feed a:3 a "$U/me-work/x"
    feed a:4 a "$H/user2/x"
    feed a:5 a "$H/example_corp/x"
  } > "$IN"
  run m < "$IN"
  [ "$status" -eq 1 ]
  [ "${#lines[@]}" -eq 5 ]
  [[ "${lines[0]}" == "a:1 patterns#"*" $U/alice-smith" ]] || false
  [[ "${lines[1]}" == "a:2 patterns#"*" $U/bob.jones" ]] || false
  [[ "${lines[2]}" == "a:3 patterns#"*" $U/me-work" ]] || false
}

@test "patterns: a bare placeholder, with a path or a closing dot, still passes" {
  {
    feed a:1 a "$U/alice"
    feed a:2 a "$U/bob/x"
    feed a:3 a "see $U/me."
    feed a:4 a "($U/you)"
    feed a:5 a "$U/name, $H/user: x"
  } > "$IN"
  run m < "$IN"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "default output carries the fragment, --redact never does" {
  feed a.md:1 a.md 'a Gizmo and gizmo corp' > "$IN"
  run m < "$IN"
  [ "$status" -eq 1 ]
  [[ "$output" == *Gizmo* ]] || false

  run mr --redact < "$IN"
  [ "$status" -eq 1 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "a.md:1 stoplist#1" ]
  [ "${lines[1]}" = "a.md:1 stoplist#2" ]
  [[ "$output" != *Gizmo* ]] || false
  [[ "$output" != *gizmo* ]] || false
}

@test "--redact keeps record text out of diagnostics too" {
  printf 'regex Zorb(\n' > "$SL"
  feed a.md:1 a.md 'x' > "$IN"
  run mr --redact < "$IN"
  [ "$status" -eq 2 ]
  [[ "$output" == *"record 1"* ]] || false
  [[ "$output" != *Zorb* ]] || false
}

@test "--redact hides a loc path that hits a rule, keeps the rest" {
  {
    feed 'docs/Gizmo-notes.md:3' docs/Gizmo-notes.md "x $U/zed/y"
    feed 'commit 3f2a1bc docs/Gizmo-notes.md:7' docs/Gizmo-notes.md "x $U/zed/y"
    feed 'commit 3f2a1bc Gizmo.swift' '' 'Gizmo.swift'
    feed "commit 3f2a1bc $U/zed/f.md" '' "$U/zed/f.md"
    feed 'tag Gizmo-1.0 message:1' '' "x $U/zed/y"
    feed 'README.md:5' README.md "x $U/zed/y"
  } > "$IN"
  run mr --redact < "$IN"
  [ "$status" -eq 1 ]
  [ "${#lines[@]}" -eq 6 ]
  [[ "$output" != *Gizmo* ]] || false
  [[ "$output" != *zed* ]] || false
  [[ "${lines[0]}" == "<redacted path>:3 patterns#"* ]] || false
  [[ "${lines[1]}" == "commit 3f2a1bc <redacted path>:7 patterns#"* ]] || false
  [ "${lines[2]}" = "commit 3f2a1bc <redacted path> stoplist#1" ]
  [[ "${lines[3]}" == "commit 3f2a1bc <redacted path> patterns#"* ]] || false
  [[ "${lines[4]}" == "tag <redacted> message:1 patterns#"* ]] || false
  [[ "${lines[5]}" == "README.md:5 patterns#"* ]] || false
}

@test "without --redact the loc is printed as is" {
  feed 'docs/Gizmo-notes.md:3' docs/Gizmo-notes.md 'clean' > "$IN"
  run m < "$IN"
  [ "$status" -eq 0 ]
  feed 'docs/Gizmo-notes.md:3' docs/Gizmo-notes.md "x $U/zed/y" > "$IN"
  run m < "$IN"
  [[ "${lines[0]}" == "docs/Gizmo-notes.md:3 patterns#"*" $U/zed" ]] || false
}

@test "validate: invalid regex fails without echoing the record" {
  printf 'regex Zorb(\n' > "$SL"
  run validate
  [ "$status" -eq 2 ]
  [[ "$output" == *"record 1"* ]] || false
  [[ "$output" != *Zorb* ]] || false
}

@test "validate: a record that matches zero-length anywhere is rejected" {
  local rec
  for rec in 'regex \b' 'regex (?=.)' 'regex ^' 'regex $'; do
    printf 'word Gizmo\n%s\n' "$rec" > "$SL"
    run validate
    [ "$status" -eq 2 ]
    [[ "$output" == "stoplist: record 2 — "* ]] || false
    [[ "$output" != *Gizmo* ]] || false
    [[ "$output" != *"${rec#regex }"* ]] || false
  done
}

@test "validate: a valid stoplist exits 0" {
  run validate
  [ "$status" -eq 0 ]
}

@test "validate: a record matching the empty string is rejected" {
  local rec
  for rec in 'regex .*' 'regex a?' 'word'; do
    printf '%s\n' "$rec" > "$SL"
    run validate
    [ "$status" -eq 2 ]
    [[ "$output" == "stoplist: record 1 — "* ]] || false
  done
}

@test "validate: allow without a matching record is rejected" {
  printf 'allow Nope spine-x:a.md\n' > "$SL"
  run validate
  [ "$status" -eq 2 ]
  [[ "$output" == *"record 1"* ]] || false
  [[ "$output" != *Nope* ]] || false
}

@test "validate: unknown kind and malformed allow are rejected without echo" {
  printf 'frob Secret\n' > "$SL"
  run validate
  [ "$status" -eq 2 ]
  [[ "$output" != *Secret* ]] || false

  printf 'word Secret\nallow Secret nocolon\n' > "$SL"
  run validate
  [ "$status" -eq 2 ]
  [[ "$output" == *"record 2"* ]] || false
  [[ "$output" != *Secret* ]] || false
}

@test "matching refuses to run on an invalid stoplist" {
  printf 'regex Zorb(\n' > "$SL"
  feed a.md:1 a.md 'x' > "$IN"
  run m < "$IN"
  [ "$status" -eq 2 ]
}

@test "CRLF stoplist works" {
  sed 's/$/\r/' "$SL" > "$SL.crlf"
  mv "$SL.crlf" "$SL"
  {
    feed a.md:1 a.md 'a Gizmo here'
    feed b.md:2 tests/ok.md 'a Gizmo here'
    feed c.md:3 c.md 'see ZORB-123'
  } > "$IN"
  run m < "$IN"
  [ "$status" -eq 1 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "a.md:1 stoplist#1 Gizmo" ]
  [ "${lines[1]}" = "c.md:3 stoplist#3 ZORB-123" ]
}

@test "comments and blank lines do not shift record ids" {
  printf '# c\n\nword Gizmo\n' > "$SL"
  feed a.md:1 a.md 'a Gizmo here' > "$IN"
  run m < "$IN"
  [ "$status" -eq 1 ]
  [ "$output" = "a.md:1 stoplist#1 Gizmo" ]
}

@test "no --stoplist: patterns only" {
  feed a.md:1 a.md 'a Gizmo here' > "$IN"
  run perl "$MATCH" --patterns "$PATTERNS" --repo spine-x < "$IN"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  feed a.md:1 a.md "$U/zed/x" > "$IN"
  run perl "$MATCH" --patterns "$PATTERNS" --repo spine-x < "$IN"
  [ "$status" -eq 1 ]
}

@test "a hit on every match in a line, one output line each" {
  feed a.md:1 a.md 'Gizmo and Gizmo' > "$IN"
  run m < "$IN"
  [ "${#lines[@]}" -eq 2 ]
}

@test "usage errors exit 2" {
  run perl "$MATCH" --repo spine-x < /dev/null
  [ "$status" -eq 2 ]
  run perl "$MATCH" --patterns "$PATTERNS" < /dev/null
  [ "$status" -eq 2 ]
  run perl "$MATCH" --patterns "$BATS_TEST_TMPDIR/missing" --repo spine-x < /dev/null
  [ "$status" -eq 2 ]
  run perl "$MATCH" --validate
  [ "$status" -eq 2 ]
}

@test "--help prints the header comment" {
  run perl "$MATCH" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--patterns"* ]] || false
}
