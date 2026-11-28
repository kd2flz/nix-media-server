#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

host="$(nix eval --raw "$repo#nixosConfigurations" --apply '
  x: builtins.concatStringsSep " "
    (builtins.filter (h: x.${h}.config.services.mediaServer.jellyfin.enable) (builtins.attrNames x))
' 2>/dev/null | awk '{print $1}')"
if [ -z "$host" ]; then
  echo 'no host enables Jellyfin; nothing to test'
  exit 0
fi

real_script="$(nix eval --raw "$repo#nixosConfigurations.$host.config.systemd.services.jellyfin.preStart")"
script="$tmp/script.sh"
perl -pe '
  s#/var/lib/jellyfin/config/system.xml#'"$tmp"'/config.xml#g;
  s#/nix/store/[^/]+-gnused[^/]+/bin/sed#sed#g;
  s#/nix/store/[^/]+-gnugrep[^/]+/bin/grep#grep#g;
' <<<"$real_script" > "$script"
chmod +x "$script"

if grep -q '/nix/store/' "$script"; then
  echo 'FAIL: unstubbed /nix/store path left in script:' >&2
  grep -n '/nix/store/' "$script" >&2
  exit 1
fi

run_case() {
  local name="$1" input="$2"
  printf '%s' "$input" > "$tmp/config.xml"
  bash "$script"
  grep -q '<EnableMetrics>true</EnableMetrics>' "$tmp/config.xml" || {
    echo "FAIL: $name did not enable metrics" >&2
    cat "$tmp/config.xml" >&2
    exit 1
  }
  if grep -q '<EnableMetrics>false</EnableMetrics>' "$tmp/config.xml"; then
    echo "FAIL: $name left metrics disabled" >&2
    exit 1
  fi
  echo "$name: ok"
}

run_case 'false value' '<Server>
  <EnableMetrics>false</EnableMetrics>
</Server>
'
run_case 'missing element' '<Server>
  <Baseline>ok</Baseline>
</Server>
'
run_case 'already enabled' '<Server>
  <EnableMetrics>true</EnableMetrics>
</Server>
'

rm -f "$tmp/config.xml"
bash "$script"
echo 'missing config file: ok'

echo 'all jellyfin-metrics cases passed'
