#!/usr/bin/env bats
# install-hooks.sh points every public checkout at the hooks of this spine-ops,
# and --check says whether it still does. These run the real scripts against
# throwaway repositories laid out like the family: a plugin, the marketplace
# that lists it, and spine-ops. gh is a stub on PATH; data is synthetic.

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

  # A stub gh on PATH: signed in, and one LEAK_STOPLIST secret with the date in
  # GH_STUB_UPDATED (none when GH_STUB_UPDATED is empty).
  mkdir -p "$W/bin"
  cat > "$W/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") [ "${GH_STUB_AUTH:-1}" = 1 ] || exit 1; exit 0 ;;
  "secret list")
    echo "$*" >> "${GH_STUB_LOG:-/dev/null}"
    if [ -n "${GH_STUB_UPDATED:-}" ]; then
      printf '[{"name":"OTHER","updatedAt":"2000-01-01T00:00:00Z"},{"name":"LEAK_STOPLIST","updatedAt":"%s"}]\n' "$GH_STUB_UPDATED"
    else
      printf '[{"name":"OTHER","updatedAt":"2000-01-01T00:00:00Z"}]\n'
    fi ;;
  "secret set")
    echo "$*" >> "${GH_STUB_LOG:-/dev/null}"
    # gh secret set LEAK_STOPLIST -R <owner>/<repo>: the value arrives on stdin.
    body="$(cat)"
    if [ -n "${GH_STUB_SET_DIR:-}" ]; then printf '%s\n' "$body" > "$GH_STUB_SET_DIR/${5//\//_}"; fi
    if [ "$5" = "${GH_STUB_FAIL:-}" ]; then printf 'gh: rejected: %s\n' "$body" >&2; exit 1; fi
    exit 0 ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$W/bin/gh"
  export PATH="$W/bin:$PATH"
}

teardown() { rm -rf "$W"; }

install_all() { for r in core market ops; do git -C "$W/$r" config --local core.hooksPath "$HOOKS"; done; }

give_github_origins() {
  local r
  for r in core market ops; do git -C "$W/$r" remote add origin "git@github.com:zed/$r.git"; done
}

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

@test "--check: a secret older than the stoplist is reported, not failed" {
  install_all; give_github_origins
  touch -t 202611110000 "$STOPLIST"
  GH_STUB_UPDATED="2026-11-10T00:00:00Z" run "$INSTALL" --check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -E '^ +core +older than stoplist$' >/dev/null
  printf '%s\n' "$output" | grep -E '^ +market +older than stoplist$' >/dev/null
  printf '%s\n' "$output" | grep -E '^ +ops +older than stoplist$' >/dev/null
}

@test "--check: a secret newer than the stoplist is ok" {
  install_all; give_github_origins
  touch -t 202611100000 "$STOPLIST"
  GH_STUB_UPDATED="2026-11-11T00:00:00Z" run "$INSTALL" --check
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -E '^ +core +ok$' >/dev/null
}

@test "--check: the stoplist's last commit date wins over its mtime, across time zones" {
  install_all; give_github_origins
  mkrepo "$W/spine-notes"
  git -C "$W/spine-notes" add -A
  # 2026-11-11 01:30 at +03:00 is 2026-11-10 22:30Z.
  GIT_AUTHOR_DATE="2026-11-11T01:30:00+03:00" GIT_COMMITTER_DATE="2026-11-11T01:30:00+03:00" \
    git -C "$W/spine-notes" commit --quiet -m stoplist
  touch -t 202701010000 "$STOPLIST"
  GH_STUB_UPDATED="2026-11-10T23:00:00Z" run "$INSTALL" --check
  printf '%s\n' "$output" | grep -E '^ +core +ok$' >/dev/null
  GH_STUB_UPDATED="2026-11-10T22:00:00Z" run "$INSTALL" --check
  printf '%s\n' "$output" | grep -E '^ +core +older than stoplist$' >/dev/null
}

@test "--check: no LEAK_STOPLIST secret in a repo is missing, and not a failure" {
  install_all; give_github_origins
  GH_STUB_UPDATED="" run "$INSTALL" --check
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -E '^ +core +missing$' >/dev/null
}

@test "--check: owner and repo come from the origin URL, ssh or https" {
  install_all
  git -C "$W/core" remote add origin "git@github.com:zed/core.git"
  git -C "$W/market" remote add origin "https://github.com/zed/market.git"
  git -C "$W/ops" remote add origin "https://github.com/zed/ops"
  GH_STUB_UPDATED="2030-01-01T00:00:00Z" GH_STUB_LOG="$W/gh.log" run "$INSTALL" --check
  [ "$status" -eq 0 ]
  grep -qF -- '-R zed/core ' "$W/gh.log"
  grep -qF -- '-R zed/market ' "$W/gh.log"
  grep -qF -- '-R zed/ops ' "$W/gh.log"
}

@test "--check: a repo without a GitHub origin has no secrets verdict, and no failure" {
  install_all
  GH_STUB_UPDATED="2030-01-01T00:00:00Z" run "$INSTALL" --check
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -E '^ +core +unknown' >/dev/null
  if printf '%s\n' "$output" | sed -n '/^secrets/,$p' | grep -E '^ +core +ok$' >/dev/null; then return 1; fi
}

@test "--check: gh not signed in, secrets skipped" {
  install_all; give_github_origins
  GH_STUB_AUTH=0 run "$INSTALL" --check
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qE '^secrets: skipped'
}

@test "--check: no gh, secrets skipped" {
  install_all; give_github_origins
  PATH="/usr/bin:/bin" run "$INSTALL" --check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -qE '^secrets: skipped'
}

@test "--check: secrets state never changes the exit code of a clean setup" {
  install_all; give_github_origins
  touch -t 202611110000 "$STOPLIST"
  GH_STUB_UPDATED="2020-01-01T00:00:00Z" run "$INSTALL" --check
  [ "$status" -eq 0 ]
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

# --- sync-leak-secret.sh -----------------------------------------------------

SYNC() { "$W/ops/leak-guard/sync-leak-secret.sh" "$@"; }

@test "sync validates first: an invalid stoplist uploads nothing" {
  give_github_origins
  printf 'word Gizmo\nregex .*\n' > "$STOPLIST"
  GH_STUB_LOG="$W/gh.log" run SYNC
  [ "$status" -ne 0 ]
  [ ! -s "$W/gh.log" ]
  if printf '%s\n' "$output" | grep -qF 'Gizmo'; then return 1; fi
}

@test "sync: a missing stoplist uploads nothing" {
  give_github_origins
  rm "$STOPLIST"
  GH_STUB_LOG="$W/gh.log" run SYNC
  [ "$status" -ne 0 ]
  [ ! -s "$W/gh.log" ]
}

@test "sync sets LEAK_STOPLIST in every roster repo, owner from origin" {
  give_github_origins
  git -C "$W/market" remote set-url origin "https://github.com/zed/market.git"
  mkdir -p "$W/sets"
  GH_STUB_LOG="$W/gh.log" GH_STUB_SET_DIR="$W/sets" run SYNC
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(grep -c . "$W/gh.log")" -eq 3 ]
  grep -qxF 'secret set LEAK_STOPLIST -R zed/core' "$W/gh.log"
  grep -qxF 'secret set LEAK_STOPLIST -R zed/market' "$W/gh.log"
  grep -qxF 'secret set LEAK_STOPLIST -R zed/ops' "$W/gh.log"
  for r in core market ops; do
    cmp "$STOPLIST" "$W/sets/zed_$r"
    printf '%s\n' "$output" | grep -qxF "$r ok"
  done
}

@test "sync takes the stoplist from LEAK_GUARD_STOPLIST" {
  give_github_origins
  rm "$STOPLIST"
  printf 'word Gizmo\n' > "$W/elsewhere.txt"
  mkdir -p "$W/sets"
  LEAK_GUARD_STOPLIST="$W/elsewhere.txt" GH_STUB_SET_DIR="$W/sets" run SYNC
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  cmp "$W/elsewhere.txt" "$W/sets/zed_core"
}

@test "sync output never contains a stoplist record, a failure included" {
  give_github_origins
  printf 'word Gizmo\nword Zorbulon\n' > "$STOPLIST"
  GH_STUB_FAIL="zed/market" run SYNC
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qxF 'core ok'
  printf '%s\n' "$output" | grep -qxF 'market failed'
  printf '%s\n' "$output" | grep -qxF 'ops ok'
  if printf '%s\n' "$output" | grep -qiE 'gizmo|zorbulon|word'; then return 1; fi
}

@test "sync: a repo without a GitHub origin is failed, the others still go" {
  give_github_origins
  git -C "$W/core" remote remove origin
  GH_STUB_LOG="$W/gh.log" run SYNC
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qxF 'core failed'
  printf '%s\n' "$output" | grep -qxF 'market ok'
  if grep -qF 'zed/core' "$W/gh.log"; then return 1; fi
}

@test "sync: no gh is an error and uploads nothing" {
  give_github_origins
  PATH="/usr/bin:/bin" GH_STUB_LOG="$W/gh.log" run SYNC
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF 'gh is not installed'
  [ ! -s "$W/gh.log" ]
}

@test "sync: an unknown argument is an error" {
  run SYNC --nope
  [ "$status" -eq 2 ]
}

# --- .github/workflows/leak-guard.yml ----------------------------------------

WORKFLOW="$BATS_TEST_DIRNAME/../.github/workflows/leak-guard.yml"

# The run: script of the step called $1, written to the file $2.
step_script() {
  ruby -ryaml -e '
    wf = YAML.load_file(ARGV[0])
    s = wf["jobs"]["scan"]["steps"].find { |x| x["name"] == ARGV[1] } or abort("no step #{ARGV[1]}")
    File.write(ARGV[2], s["run"])' "$WORKFLOW" "$1" "$2"
}

@test "workflow parses and has the triggers, the optional secret and read-only permissions" {
  run ruby -ryaml -e '
    wf = YAML.load_file(ARGV[0])
    on = wf["on"] || wf[true]
    s = on["workflow_call"]["secrets"]["LEAK_STOPLIST"]
    abort("secret must be optional") unless s["required"] == false
    %w[push pull_request schedule workflow_dispatch].each { |k| abort("no #{k}") unless on.key?(k) }
    abort("cron") unless on["schedule"].map { |x| x["cron"] } == ["0 6 * * 1"]
    abort("permissions") unless wf["permissions"] == { "contents" => "read" }
    abort("one job") unless wf["jobs"].size == 1 && wf["jobs"]["scan"]["runs-on"] == "ubuntu-latest"
    co = wf["jobs"]["scan"]["steps"].first
    abort("checkout") unless co["uses"] == "actions/checkout@v4" && co["with"]["fetch-depth"] == 0' "$WORKFLOW"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "workflow: no run block interpolates an expression, no step traces the shell" {
  run ruby -ryaml -e '
    wf = YAML.load_file(ARGV[0])
    wf["jobs"].each_value do |j|
      j["steps"].each do |s|
        next unless s["run"]
        abort("expression in run: #{s["name"]}") if s["run"].include?("${{")
        abort("set -x in #{s["name"]}") if s["run"] =~ /set\s+-\w*x/
      end
    end' "$WORKFLOW"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "workflow: the scanner of another repo is checked out with no hardcoded owner" {
  run ruby -ryaml -e '
    wf = YAML.load_file(ARGV[0])
    s = wf["jobs"]["scan"]["steps"].find { |x| x["name"] == "Check out spine-ops" }
    abort("owner") unless s["with"]["repository"] == "${{ github.repository_owner }}/spine-ops"
    abort("path") unless s["with"]["path"] == ".leak-guard-ops"
    abort("if") unless s["if"].start_with?("github.repository != format(\x27{0}/spine-ops\x27, github.repository_owner)")' "$WORKFLOW"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "workflow: a pull request to spine-ops itself is scanned by the scanner of its base commit" {
  run ruby -ryaml -e '
    wf = YAML.load_file(ARGV[0])
    s = wf["jobs"]["scan"]["steps"].find { |x| x["name"] == "Check out spine-ops" }
    abort("runs for own pull requests") unless s["if"].include?("github.event_name == \x27pull_request\x27")
    abort("base sha") unless s["with"]["ref"].include?("github.event.pull_request.base.sha")
    abort("not own-only") unless s["with"]["ref"].include?("github.repository == format(")
    l = wf["jobs"]["scan"]["steps"].find { |x| x["name"] == "Locate the scanner" }
    abort("working copy only outside a PR") unless l["env"]["OWN_WORKING_COPY"].include?("github.event_name != \x27pull_request\x27")' "$WORKFLOW"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  step_script "Locate the scanner" "$W/locate.sh"
  : > "$W/env"
  OWN_WORKING_COPY=true GITHUB_ENV="$W/env" run bash -e "$W/locate.sh"
  grep -qxF 'LEAK_GUARD_SCAN=leak-guard/scan.sh' "$W/env"
  : > "$W/env"
  OWN_WORKING_COPY=false GITHUB_ENV="$W/env" run bash -e "$W/locate.sh"
  grep -qxF 'LEAK_GUARD_SCAN=.leak-guard-ops/leak-guard/scan.sh' "$W/env"
}

@test "workflow: a push that deletes a ref is skipped by the job and by the scan step" {
  run ruby -ryaml -e '
    j = YAML.load_file(ARGV[0])["jobs"]["scan"]
    abort("job if") unless j["if"] == "github.event_name != \x27push\x27 || !github.event.deleted"' "$WORKFLOW"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  step_script "Scan what this event brings" "$W/scan-step.sh"
  printf '#!/usr/bin/env bash\necho called >> "%s/called"\n' "$W" > "$W/stub-scan.sh"
  cd "$W/core"
  EVENT_NAME=push REF=refs/tags/1.2.0 BEFORE=1111111111111111111111111111111111111111 AFTER=0000000000000000000000000000000000000000 \
    LEAK_GUARD_SCAN="$W/stub-scan.sh" run bash -e "$W/scan-step.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -e "$W/called" ]
}

@test "workflow: spine-ops stays clean under its own patterns" {
  run "$BATS_TEST_DIRNAME/../leak-guard/scan.sh" --patterns-only --tree
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "workflow: a checkout of the scanner inside the caller is not part of its --tree" {
  mkdir -p "$W/core/.leak-guard-ops/leak-guard"
  mkrepo "$W/core/.leak-guard-ops"
  echo 'Gizmo' > "$W/core/.leak-guard-ops/leak-guard/note.txt"
  git -C "$W/core/.leak-guard-ops" add -A
  git -C "$W/core/.leak-guard-ops" commit --quiet -m note
  cd "$W/core"
  run "$W/ops/leak-guard/scan.sh" --redact --tree
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "workflow stoplist step: the secret goes to a private file, never to the output" {
  step_script "Prepare the stoplist" "$W/step.sh"
  : > "$W/env"; mkdir -p "$W/tmp"
  STOPLIST=$'word Gizmo\nword Zorbulon' IS_FORK_PR=false RUNNER_TEMP="$W/tmp" GITHUB_ENV="$W/env" run bash -e "$W/step.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  if printf '%s\n' "$output" | grep -qi 'gizmo\|zorbulon'; then return 1; fi
  [ "$(cat "$W/tmp/stoplist")" = "$(printf 'word Gizmo\nword Zorbulon')" ]
  [ "$(perl -e 'printf "%o", (stat $ARGV[0])[2] & 0777' "$W/tmp/stoplist")" = 600 ]
  grep -qxF "LEAK_GUARD_STOPLIST=$W/tmp/stoplist" "$W/env"
}

@test "workflow stoplist step: a fork pull request without the secret warns and goes patterns-only" {
  step_script "Prepare the stoplist" "$W/step.sh"
  : > "$W/env"
  STOPLIST="" IS_FORK_PR=true RUNNER_TEMP="$W" GITHUB_ENV="$W/env" run bash -e "$W/step.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = "::warning::LEAK_STOPLIST unavailable to a fork pull request: only public patterns were checked" ]
  grep -qxF 'LEAK_GUARD_PATTERNS_ONLY=1' "$W/env"
  if grep -q STOPLIST= "$W/env"; then return 1; fi
}

@test "workflow stoplist step: anything else without the secret fails" {
  step_script "Prepare the stoplist" "$W/step.sh"
  : > "$W/env"
  STOPLIST="" IS_FORK_PR=false RUNNER_TEMP="$W" GITHUB_ENV="$W/env" run bash -e "$W/step.sh"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qxF '::error::secret LEAK_STOPLIST is not set — run spine-ops/leak-guard/sync-leak-secret.sh'
  [ ! -s "$W/env" ]
}

# Run the scan step against a stub scanner that prints its arguments.
run_scan_step() {
  step_script "Scan what this event brings" "$W/scan-step.sh"
  printf '#!/usr/bin/env bash\necho "$*"\n' > "$W/stub-scan.sh"
  cd "$W/core"
  LEAK_GUARD_SCAN="$W/stub-scan.sh" run bash -e "$W/scan-step.sh"
}

@test "workflow scan step: a branch push scans before..after" {
  echo more >> "$W/core/README.md"; commit_all "$W/core"
  after="$(git -C "$W/core" rev-parse HEAD)"; before="$(git -C "$W/core" rev-parse HEAD~1)"
  EVENT_NAME=push REF=refs/heads/main BEFORE="$before" AFTER="$after" run_scan_step
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = "--redact --range $before..$after" ]
}

@test "workflow scan step: a new branch or an unreachable before scans the history" {
  after="$(git -C "$W/core" rev-parse HEAD)"
  EVENT_NAME=push REF=refs/heads/main BEFORE=0000000000000000000000000000000000000000 AFTER="$after" run_scan_step
  [ "$output" = "--redact --history" ]
  EVENT_NAME=push REF=refs/heads/main BEFORE=1111111111111111111111111111111111111111 AFTER="$after" run_scan_step
  [ "$output" = "--redact --history" ]
}

@test "workflow scan step: a tag push scans the tag" {
  after="$(git -C "$W/core" rev-parse HEAD)"
  EVENT_NAME=push REF=refs/tags/1.2.0 BEFORE=0000000000000000000000000000000000000000 AFTER="$after" run_scan_step
  [ "$output" = "--redact --tag 1.2.0" ]
}

@test "workflow scan step: a pull request scans base..head, schedule and dispatch scan the history" {
  EVENT_NAME=pull_request REF=refs/pull/1/merge BASE_SHA=aaa HEAD_SHA=bbb run_scan_step
  [ "$output" = "--redact --range aaa..bbb" ]
  EVENT_NAME=schedule REF=refs/heads/main run_scan_step
  [ "$output" = "--redact --history" ]
  EVENT_NAME=workflow_dispatch REF=refs/heads/main run_scan_step
  [ "$output" = "--redact --history" ]
}

@test "workflow scan step: patterns-only is passed on, and the scanner's failure fails the step" {
  LEAK_GUARD_PATTERNS_ONLY=1 EVENT_NAME=schedule REF=refs/heads/main run_scan_step
  [ "$output" = "--redact --patterns-only --history" ]
  step_script "Scan what this event brings" "$W/scan-step.sh"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$W/stub-scan.sh"
  cd "$W/core"
  EVENT_NAME=schedule REF=refs/heads/main LEAK_GUARD_SCAN="$W/stub-scan.sh" run bash -e "$W/scan-step.sh"
  [ "$status" -eq 1 ]
}

@test "workflow tree step: runs on its own, redacted, and honours patterns-only" {
  step_script "Scan the tree as it is" "$W/tree-step.sh"
  printf '#!/usr/bin/env bash\necho "$*"\n' > "$W/stub-scan.sh"
  cd "$W/core"
  LEAK_GUARD_SCAN="$W/stub-scan.sh" run bash -e "$W/tree-step.sh"
  [ "$output" = "--redact --tree" ]
  LEAK_GUARD_PATTERNS_ONLY=1 LEAK_GUARD_SCAN="$W/stub-scan.sh" run bash -e "$W/tree-step.sh"
  [ "$output" = "--redact --patterns-only --tree" ]
  ruby -ryaml -e 's = YAML.load_file(ARGV[0])["jobs"]["scan"]["steps"].last; abort unless s["if"].include?("!cancelled()") && s["if"].include?("steps.stoplist.outcome")' "$WORKFLOW"
}
