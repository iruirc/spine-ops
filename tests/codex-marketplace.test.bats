#!/usr/bin/env bats
# The Codex catalogue is derived from the canonical Claude roster. It has no
# version copies of its own, but its membership, Git sources and policy must not
# drift from the plugin checkouts.

setup() {
  W="$(mktemp -d)"
  mkdir -p "$W/ops/scripts" "$W/market/.claude-plugin" "$W/market/.agents/plugins"
  mkdir -p "$W/platform/.claude-plugin" "$W/platform/.codex-plugin"
  cp "$BATS_TEST_DIRNAME/../scripts/lib.sh" "$W/ops/scripts/lib.sh"

  cat > "$W/ops/repos.json" <<'JSON'
{
  "marketplace": { "path": "../market" },
  "checkouts": {
    "platform": { "path": "../platform" }
  }
}
JSON
  cat > "$W/market/.claude-plugin/marketplace.json" <<'JSON'
{
  "name": "test",
  "version": "1.0.0",
  "plugins": [{ "name": "platform", "version": "1.0.0" }]
}
JSON
  cat > "$W/platform/.claude-plugin/plugin.json" <<'JSON'
{ "name": "platform", "version": "1.0.0" }
JSON
  cat > "$W/platform/.codex-plugin/plugin.json" <<'JSON'
{
  "name": "platform",
  "version": "1.0.0",
  "repository": "https://github.com/example/platform"
}
JSON
  write_codex_marketplace "https://github.com/example/platform.git"
  . "$W/ops/scripts/lib.sh"
}

teardown() { rm -rf "$W"; }

write_codex_marketplace() {
  local url="$1"
  cat > "$W/market/.agents/plugins/marketplace.json" <<JSON
{
  "name": "test",
  "interface": { "displayName": "Test" },
  "plugins": [
    {
      "name": "platform",
      "source": { "source": "url", "url": "$url", "ref": "main" },
      "policy": { "installation": "AVAILABLE", "authentication": "ON_INSTALL" },
      "category": "Developer Tools"
    }
  ]
}
JSON
}

@test "a complete Git-backed Codex projection passes" {
  run codex_marketplace_errors
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -z "$output" ]
}

@test "a plugin with a Codex manifest cannot disappear from the projection" {
  jq '.plugins = []' "$W/market/.agents/plugins/marketplace.json" > "$W/empty.json"
  mv "$W/empty.json" "$W/market/.agents/plugins/marketplace.json"

  run codex_marketplace_errors
  [ "$status" -ne 0 ]
  [[ "$output" == *"roster differs"* ]] || { echo "$output"; return 1; }
}

@test "a Codex entry must use the repository declared by its plugin" {
  write_codex_marketplace "https://github.com/example/wrong.git"

  run codex_marketplace_errors
  [ "$status" -ne 0 ]
  [[ "$output" == *"wrong Git source or policy"* ]] || { echo "$output"; return 1; }
}
