#!/usr/bin/env bats
# The arithmetic that decides which version a release lands on. It is the one
# part of this repository where a wrong answer is silent: a bad comparison does
# not fail, it tags the wrong number.

setup() { . "$BATS_TEST_DIRNAME/../scripts/lib.sh"; }

@test "bump moves one field and zeroes the ones below it" {
  [ "$(bump 1.3.1 patch)" = "1.3.2" ]
  [ "$(bump 1.3.1 minor)" = "1.4.0" ]
  [ "$(bump 1.3.1 major)" = "2.0.0" ]
}

@test "bump crosses a ten boundary numerically, not textually" {
  # 1.9.0 -> 1.10.0, never 1.10 sorted under 1.9.
  [ "$(bump 1.9.0 minor)" = "1.10.0" ]
  [ "$(bump 1.9.9 patch)" = "1.9.10" ]
}

@test "bump refuses a non-version and an unknown increment" {
  run bump "1.3" minor
  [ "$status" -ne 0 ]
  run bump 1.3.1 sideways
  [ "$status" -ne 0 ]
}

@test "semver_gt compares fields as numbers" {
  # The trap: as text, 1.10.0 sorts below 1.9.0, and a release would be refused
  # for not being above the version it is plainly above.
  semver_gt 1.10.0 1.9.0
  run semver_gt 1.9.0 1.10.0
  [ "$status" -ne 0 ]
}

@test "semver_gt is strict: equal is not greater" {
  run semver_gt 1.3.1 1.3.1
  [ "$status" -ne 0 ]
}

@test "kind_between names the field that moved" {
  [ "$(kind_between 1.3.1 1.3.2)" = "patch" ]
  [ "$(kind_between 1.3.1 1.4.0)" = "minor" ]
  [ "$(kind_between 1.3.1 2.0.0)" = "major" ]
  [ "$(kind_between 1.9.0 1.10.0)" = "minor" ]
}

@test "kind_between reads the highest field that moved, not the lowest" {
  # 1.3.1 -> 2.4.5 moves all three; only the major one is the answer.
  [ "$(kind_between 1.3.1 2.4.5)" = "major" ]
  [ "$(kind_between 1.3.1 1.4.5)" = "minor" ]
}

@test "kind_between refuses anything that is not a pair of versions" {
  run kind_between 1.3.1 "minor"
  [ "$status" -ne 0 ]
}

@test "is_semver accepts three numeric fields and nothing else" {
  is_semver 0.0.0
  is_semver 10.20.30
  for bad in 1.3 1.3.1.1 v1.3.1 1.3.x ""; do
    run is_semver "$bad"
    [ "$status" -ne 0 ] || { echo "is_semver accepted '$bad'"; return 1; }
  done
}
