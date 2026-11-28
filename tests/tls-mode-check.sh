#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

render() {
  local mode="$1"
  REPO="$repo" MODE="$mode" nix eval --raw --impure --expr '
let
  repo = builtins.getEnv "REPO";
  mode = builtins.getEnv "MODE";
  flake = builtins.getFlake repo;
  system = builtins.currentSystem;
  lib = flake.inputs.nixpkgs.lib;
  systemConfig = lib.nixosSystem {
    inherit system;
    modules = [
      (repo + "/modules/media-server.nix")
      (repo + "/modules/monitoring.nix")
      flake.inputs.nanitor.nixosModules.nanitor-agent
      flake.inputs.kace-ampagent.nixosModules.kace-ampagent
      flake.inputs.sops-nix.nixosModules.sops
      flake.inputs.comin.nixosModules.comin
      {
        services.mediaServer = {
          enable = true;
          domainBase = "example.invalid";
          tlsMode = mode;
          gpu = "none";
          jellyfin.enable = true;
          audiobookshelf.enable = false;
          wizarr.enable = false;
          dispatcharr.enable = false;
        };
        services.monitoring.enable = false;
      }
    ];
  };
in systemConfig.config.services.caddy.extraConfig
' > "$tmp/$mode.conf"
}

render none
grep -q 'jellyfin.example.invalid' "$tmp/none.conf"
grep -q 'reverse_proxy 127.0.0.1:8096' "$tmp/none.conf"
if grep -qE '^[[:space:]]+tls([[:space:]]|$)' "$tmp/none.conf"; then
  echo 'FAIL: tlsMode none still rendered a tls directive' >&2
  cat "$tmp/none.conf" >&2
  exit 1
fi
echo 'tlsMode none: ok'

render internal
grep -q 'jellyfin.example.invalid' "$tmp/internal.conf"
grep -q 'reverse_proxy 127.0.0.1:8096' "$tmp/internal.conf"
grep -q 'tls internal' "$tmp/internal.conf"
echo 'tlsMode internal: ok'

echo 'all tls-mode cases passed'
