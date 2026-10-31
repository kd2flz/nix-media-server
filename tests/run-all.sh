#!/usr/bin/env bash
#
# Single entry point for every local test. CI and humans both run this.
#   ./tests/run-all.sh
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

step() { printf '\n==> %s\n' "$*"; }

step 'nix flake check (evaluates every host)'
nix flake check

step 'live-sports-epg unit tests'
if command -v node >/dev/null 2>&1; then node_cmd=(node); else node_cmd=(nix shell nixpkgs#nodejs -c node); fi
(cd packages/live-sports-epg && "${node_cmd[@]}" --test test/*.test.js)

# Every executable tests/*.sh harness except this runner.
for t in tests/*.sh; do
  [ "$t" = "tests/run-all.sh" ] && continue
  step "$t"
  "./$t"
done

printf '\nall tests passed\n'
