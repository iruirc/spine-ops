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
