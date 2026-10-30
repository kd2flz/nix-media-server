#!/usr/bin/env bash
#
# Exercise the nvidia-driver-check script and assert the alert wiring, without
# needing an NVIDIA GPU. The real store paths are substituted with local stubs.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/textfile"
cat > "$tmp/bin/nvidia-smi" <<'EOF'
#!/usr/bin/env bash
exit "${NV_OK:?NV_OK is required}"
EOF
cat > "$tmp/bin/date" <<'EOF'
#!/usr/bin/env bash
echo 1700000000
EOF
chmod +x "$tmp/bin/"*

host="$(nix eval --raw "$repo#nixosConfigurations" --apply '
  x: builtins.concatStringsSep " "
    (builtins.filter (h: x.${h}.config.services.mediaServer.gpu == "nvidia") (builtins.attrNames x))
' 2>/dev/null | awk '{print $1}')"
if [ -z "$host" ]; then
  echo 'no host has gpu = "nvidia"; nothing to test'
  exit 0
fi

real_script="$(nix eval --raw "$repo#nixosConfigurations.$host.config.systemd.services.nvidia-driver-check.script")"
script="$tmp/script.sh"
perl -pe '
  s#/nix/store/[^/]+-nvidia[^/]+/bin/nvidia-smi#'"$tmp"'/bin/nvidia-smi#g;
  s#/nix/store/[^/]+-coreutils[^/]+/bin/date#'"$tmp"'/bin/date#g;
  s#/var/lib/node-exporter/textfile#'"$tmp"'/textfile#g;
' <<<"$real_script" > "$script"
chmod +x "$script"

run_case() {
  local nv_ok="$1" expect="$2"
  export NV_OK="$nv_ok"
  rm -f "$tmp/textfile/nvidia_driver.prom" "$tmp/textfile/nvidia_driver.prom.tmp"
  bash "$script"
  grep -q "^nvidia_driver_ok $expect$" "$tmp/textfile/nvidia_driver.prom"
  grep -q '^nvidia_driver_last_check_timestamp_seconds 1700000000$' "$tmp/textfile/nvidia_driver.prom"
  test ! -e "$tmp/textfile/nvidia_driver.prom.tmp"
  echo "nvidia-smi exit $nv_ok -> nvidia_driver_ok $expect: ok"
}

run_case 0 1
run_case 1 0

expr="$(nix eval --json "$repo#nixosConfigurations.$host.config.services.grafana.provision.alerting.rules.settings" \
  | grep -o '"expr":"[^"]*"' | grep 'nvidia_driver' | head -1)"
grep -q 'nvidia_driver_ok == 0' <<<"$expr"
grep -q 'nvidia_driver_last_check_timestamp_seconds' <<<"$expr"
grep -q 'absent(' <<<"$expr"
echo 'nvidia alert expression includes mismatch, stale, and missing-metric checks: ok'

echo 'all nvidia-check cases passed'
