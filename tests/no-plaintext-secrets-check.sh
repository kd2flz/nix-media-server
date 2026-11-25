#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0

check_absent() {
  local label="$1"
  local pattern="$2"
  shift 2
  if grep -R -n -E "$pattern" "$@" >/dev/null 2>&1; then
    echo "FAIL: $label" >&2
    fail=1
  else
    echo "ok: $label"
  fi
}

check_absent "no plaintext heartbeat URLs in config or docs" \
  'hc-ping\.com/' \
  "$repo/hosts" "$repo/modules" "$repo/README.md" "$repo/AGENTS.md" "$repo/docs"

check_absent "no exposed Dispatcharr MCP wiring" \
  'dispatcharrMcp|dispatcharr-mcp|:8000/mcp' \
  "$repo/hosts" "$repo/modules" "$repo/opencode.json" "$repo/README.md" "$repo/AGENTS.md" "$repo/docs"

check_absent "no hardcoded Grafana credentials or first-boot password" \
  'SW2YcwTIb9zpOOhoPsMm|admin_password = "admin"|pleasechangeme' \
  "$repo/hosts" "$repo/modules" "$repo/README.md" "$repo/AGENTS.md" "$repo/docs"

check_absent "no internal NTP servers in common module" \
  '192\.168\.(2\.19|82\.19)' \
  "$repo/modules/common.nix"

exit "$fail"
