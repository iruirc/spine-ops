#!/usr/bin/env bats
# The editor exists to change one line. A jq round-trip would reformat these
# manifests, and a release diff that reflows a file hides what it actually did.

setup() {
  SET="$BATS_TEST_DIRNAME/../scripts/set-version.py"
  WORK="$(mktemp -d)"
  MANIFEST="$WORK/marketplace.json"
  cat > "$MANIFEST" <<'JSON'
{
  "name": "iruirc",
  "version": "1.2.0",
  "owner": { "name": "Someone" },
  "plugins": [
    {
      "name": "alpha",
      "description": "first",
      "version": "1.1.0"
    },
    {
      "name": "beta",
      "description": "second",
      "version": "2.0.0"
    }
  ]
}
JSON
}

teardown() { rm -rf "$WORK"; }

# The trailing newline matters: $(cat) strips it, and without putting it back
# diff calls the last line changed too, on every comparison.
changed_lines() { diff <(printf '%s\n' "$1") "$MANIFEST" | grep -c '^>' || true; }

@test "the top-level version is the one changed, and only that line" {
  before="$(cat "$MANIFEST")"
  "$SET" "$MANIFEST" 1.3.0
  [ "$(changed_lines "$before")" -eq 1 ]
  [ "$(jq -r '.version' "$MANIFEST")" = "1.3.0" ]
  [ "$(jq -r '.plugins[0].version' "$MANIFEST")" = "1.1.0" ]
}

@test "a plugin's version is reached by name, not by position" {
  before="$(cat "$MANIFEST")"
  "$SET" "$MANIFEST" 2.1.0 --plugin beta
  [ "$(changed_lines "$before")" -eq 1 ]
  [ "$(jq -r '.plugins[1].version' "$MANIFEST")" = "2.1.0" ]
  [ "$(jq -r '.plugins[0].version' "$MANIFEST")" = "1.1.0" ]
  [ "$(jq -r '.version' "$MANIFEST")" = "1.2.0" ]
}

@test "the one-line object survives the edit" {
  # json.dumps would split `"owner": { "name": ... }` across three lines.
  "$SET" "$MANIFEST" 1.3.0
  grep -q '"owner": { "name": "Someone" },' "$MANIFEST"
}

@test "the file is still valid json afterwards" {
  "$SET" "$MANIFEST" 1.3.0
  "$SET" "$MANIFEST" 9.9.9 --plugin alpha
  jq . "$MANIFEST" >/dev/null
}

@test "setting the version it already carries is refused" {
  run "$SET" "$MANIFEST" 1.2.0
  [ "$status" -ne 0 ]
  [ "$(jq -r '.version' "$MANIFEST")" = "1.2.0" ]
}

@test "a plugin the manifest does not list is refused, and nothing is written" {
  before="$(cat "$MANIFEST")"
  run "$SET" "$MANIFEST" 1.0.0 --plugin gamma
  [ "$status" -ne 0 ]
  [ "$(cat "$MANIFEST")" = "$before" ]
}

@test "a plugin entry with no version of its own is refused rather than editing the next one" {
  cat > "$MANIFEST" <<'JSON'
{
  "plugins": [
    {
      "name": "alpha",
      "description": "first, and no version"
    },
    {
      "name": "beta",
      "version": "2.0.0"
    }
  ]
}
JSON
  before="$(cat "$MANIFEST")"
  run "$SET" "$MANIFEST" 1.1.0 --plugin alpha
  [ "$status" -ne 0 ]
  [ "$(cat "$MANIFEST")" = "$before" ]
}

# A plugin can quote its own version as a dependency floor in files a release has
# to move with it — a reference copy of that line in a doc or a fixture.
@test "a plugin's own floor is rewritten on every line that quotes it, and nowhere else" {
  FLOORS="$WORK/driver.md"
  cat > "$FLOORS" <<'MD'
One line of plugin.json:

    { "name": "core", "version": ">=1.7.3 <2" },
    { "name": "other", "version": ">=1.7.3 <2" }

and the same line again, in prose: `{ "name": "core", "version": ">=1.7.3 <2" }`.
MD
  "$SET" "$FLOORS" 1.8.0 --floor core
  [ "$(grep -c '"name": "core", "version": ">=1.8.0 <2"' "$FLOORS" || true)" -eq 2 ]
  [ "$(grep -c '"name": "core", "version": ">=1.7.3' "$FLOORS" || true)" -eq 0 ]
  grep -q '"name": "other", "version": ">=1.7.3 <2"' "$FLOORS"
}

@test "a major release moves the floor's upper bound with it" {
  FLOORS="$WORK/plugin.json"
  printf '{\n  "dependencies": [ { "name": "core", "version": ">=1.9.0 <2" } ]\n}\n' > "$FLOORS"
  "$SET" "$FLOORS" 2.0.0 --floor core
  [ "$(jq -r '.dependencies[0].version' "$FLOORS")" = ">=2.0.0 <3" ]
}

@test "a file that quotes no floor for that plugin is refused, and nothing is written" {
  # The control proves --floor is understood at all; without it, a usage error on
  # an unknown flag would pass for the refusal.
  printf '{ "dependencies": [ { "name": "core", "version": ">=1.0.0 <2" } ] }\n' > "$WORK/control.json"
  "$SET" "$WORK/control.json" 1.8.0 --floor core
  FLOORS="$WORK/plugin.json"
  printf '{ "dependencies": [ { "name": "other", "version": ">=1.0.0 <2" } ] }\n' > "$FLOORS"
  before="$(cat "$FLOORS")"
  run "$SET" "$FLOORS" 1.8.0 --floor core
  [ "$status" -ne 0 ]
  [ "$(cat "$FLOORS")" = "$before" ]
}
