#!/usr/bin/env bats
# install-hooks.sh points every public checkout at the hooks of this spine-ops,
# and --check says whether it still does. These run the real scripts against
# throwaway repositories laid out like the family: a plugin, the marketplace
# that lists it, and spine-ops. Data is synthetic.

mkrepo() {
  mkdir -p "$1"
  git -C "$1" init --quiet -b main
  git -C "$1" config user.email t@example.com
  git -C "$1" config user.name Test
}

commit_all() { git -C "$1" add -A; git -C "$1" commit --quiet -m change; }

hooks_path() { git -C "$1" config --local --get core.hooksPath || true; }

setup() {
  W="$(mktemp -d)"
  W="$(cd "$W" && pwd -P)"
  unset LEAK_GUARD_STOPLIST
  # Anything written to the global config would land here, not in the real one.
  export HOME="$W/home"
  mkdir -p "$HOME"

  mkrepo "$W/core"
  echo core > "$W/core/README.md"; commit_all "$W/core"

  mkrepo "$W/market"
  mkdir -p "$W/market/.claude-plugin"
  cat > "$W/market/.claude-plugin/marketplace.json" <<'JSON'
{
  "name": "test",
  "version": "1.0.0",
  "plugins": [ { "name": "core", "version": "1.0.0" } ]
}
JSON
  commit_all "$W/market"

  mkdir -p "$W/ops"
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
  mkrepo "$W/ops"; commit_all "$W/ops"

  HOOKS="$W/ops/leak-guard/hooks"
  INSTALL="$W/ops/leak-guard/install-hooks.sh"

  # The stoplist where scan.sh looks by default: <ops>/../spine-notes/...
  mkdir -p "$W/spine-notes/leak-guard"
  STOPLIST="$W/spine-notes/leak-guard/stoplist.txt"
  printf '# format\nword Gizmo\n\nci gizmo corp\nregex ZORB-[0-9]+\n' > "$STOPLIST"
}

teardown() { rm -rf "$W"; }

install_all() { for r in core market ops; do git -C "$W/$r" config --local core.hooksPath "$HOOKS"; done; }

@test "install sets core.hooksPath in every roster repo" {
  run "$INSTALL"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  for r in core market ops; do
    [ "$(hooks_path "$W/$r")" = "$HOOKS" ]
  done
  [ ! -e "$HOME/.gitconfig" ]
  [ ! -e "$HOME/.config/git/config" ]
}

@test "install repairs a core.hooksPath that points at a folder that is gone" {
  git -C "$W/core" config --local core.hooksPath "$W/gone"
  run "$INSTALL"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(hooks_path "$W/core")" = "$HOOKS" ]
}

@test "a second install changes nothing" {
  run "$INSTALL"
  [ "$status" -eq 0 ]
  before="$(cat "$W/core/.git/config" "$W/market/.git/config" "$W/ops/.git/config")"
  run "$INSTALL"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qi 'nothing to do'
  after="$(cat "$W/core/.git/config" "$W/market/.git/config" "$W/ops/.git/config")"
  [ "$before" = "$after" ]
}

@test "a foreign core.hooksPath is left alone and named" {
  mkdir -p "$W/other-hooks"
  git -C "$W/market" config --local core.hooksPath "$W/other-hooks"
  run "$INSTALL"
  [ "$status" -eq 1 ]
  [ "$(hooks_path "$W/market")" = "$W/other-hooks" ]
  printf '%s\n' "$output" | grep -F 'market' | grep -qi 'foreign'
  # The others are still processed.
  [ "$(hooks_path "$W/core")" = "$HOOKS" ]
  [ "$(hooks_path "$W/ops")" = "$HOOKS" ]
}

@test "install does not need the stoplist" {
  rm "$STOPLIST"
  run "$INSTALL"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "--check: all installed and a good stoplist is ok, with the record count" {
  install_all
  run "$INSTALL" --check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -qE '^stoplist: ok \(3 records\)$'
  for r in core market ops; do
    printf '%s\n' "$output" | grep -E "^ +$r +ok$" >/dev/null
  done
}

@test "--check: missing, broken path and foreign are told apart" {
  mkdir -p "$W/other-hooks"
  git -C "$W/market" config --local core.hooksPath "$W/gone"
  git -C "$W/ops" config --local core.hooksPath "$W/other-hooks"
  run "$INSTALL" --check
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -E '^ +core +missing$' >/dev/null
  printf '%s\n' "$output" | grep -E '^ +market +broken path$' >/dev/null
  printf '%s\n' "$output" | grep -E '^ +ops +foreign$' >/dev/null
}

@test "--check: a relative core.hooksPath and a symlinked hooks folder still read as ok" {
  ln -s "$HOOKS" "$W/link-hooks"
  git -C "$W/core" config --local core.hooksPath "$W/link-hooks"
  git -C "$W/market" config --local core.hooksPath "$HOOKS/"
  git -C "$W/ops" config --local core.hooksPath "leak-guard/hooks"
  run "$INSTALL" --check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "--check: a global core.hooksPath does not count as installed" {
  git config --global core.hooksPath "$HOOKS"
  run "$INSTALL" --check
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -E '^ +core +missing$' >/dev/null
}

@test "--check: stoplist missing makes the check fail" {
  install_all
  rm "$STOPLIST"
  run "$INSTALL" --check
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qE '^stoplist: missing$'
}

@test "--check: an invalid stoplist makes the check fail" {
  install_all
  printf 'word Gizmo\nregex .*\n' > "$STOPLIST"
  run "$INSTALL" --check
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qE '^stoplist: invalid$'
}

@test "--check: LEAK_GUARD_STOPLIST overrides the default place" {
  install_all
  rm "$STOPLIST"
  printf 'word Gizmo\n' > "$W/elsewhere.txt"
  LEAK_GUARD_STOPLIST="$W/elsewhere.txt" run "$INSTALL" --check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -qE '^stoplist: ok \(1 records\)$'
}

@test "--check never prints a stoplist record" {
  install_all
  printf 'word Gizmo\nword Zorbulon\n' > "$STOPLIST"
  run "$INSTALL" --check
  if printf '%s\n' "$output" | grep -qi 'zorbulon'; then return 1; fi
  printf 'regex (\n' > "$STOPLIST"
  run "$INSTALL" --check
  if printf '%s\n' "$output" | grep -qF 'regex'; then return 1; fi
}

@test "an unknown argument is an error" {
  run "$INSTALL" --nope
  [ "$status" -eq 2 ]
}

@test "leak_roster: plugins by name, marketplace and spine-ops by folder" {
  run bash -c '. "$1/leak-guard/roster.sh"; leak_roster' _ "$W/ops"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = "$(printf 'core\t%s\nmarket\t%s\nops\t%s' "$W/core" "$W/market" "$W/ops")" ]
}

@test "leak_hooks_ok: 0 iff core.hooksPath is this spine-ops's hooks" {
  run bash -c '. "$1/leak-guard/roster.sh"; leak_hooks_ok "$2"' _ "$W/ops" "$W/core"
  [ "$status" -ne 0 ]
  git -C "$W/core" config --local core.hooksPath "$HOOKS"
  run bash -c '. "$1/leak-guard/roster.sh"; leak_hooks_ok "$2"' _ "$W/ops" "$W/core"
  [ "$status" -eq 0 ]
  git -C "$W/core" config --local core.hooksPath "$W/ops/scripts"
  run bash -c '. "$1/leak-guard/roster.sh"; leak_hooks_ok "$2"' _ "$W/ops" "$W/core"
  [ "$status" -ne 0 ]
}
