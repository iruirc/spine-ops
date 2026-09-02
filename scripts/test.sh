#!/usr/bin/env bash
# Run the suite. Read-only: nothing here touches a managed repository.
set -euo pipefail

case "${1:-}" in
  -h|--help) sed -n '2p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; echo "usage: test.sh"; exit 0 ;;
  "") ;;
  *) echo "error: test.sh takes no arguments" >&2; exit 2 ;;
esac

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
command -v bats >/dev/null || { echo "error: bats-core not on PATH. install: brew install bats-core" >&2; exit 3; }
bats "$root/tests"
