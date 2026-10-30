#!/usr/bin/env bash
#
# For every host in the flake, assert that the monitoring wiring matches what
# that host's own config enables. No hostnames are hardcoded: adding
# hosts/<name>/ automatically adds it to this check.
#
#   Dispatcharr enabled        <=> dispatcharr probe + alert
#   live-sports EPG enabled    <=> live-sports-epg probe + alert (listenPort > 0)
#   gpu = "nvidia"             <=> nvidia-driver-check service/timer + alert
#   dead-man switch + URL set  <=> deadman-ping service/timer
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0

hosts="$(nix eval --raw "$repo#nixosConfigurations" \
  --apply 'x: builtins.concatStringsSep " " (builtins.attrNames x)' 2>/dev/null)"
[ -n "$hosts" ] || { echo 'FAIL: no hosts discovered' >&2; exit 1; }

for host in $hosts; do
  lines="$(nix eval --raw "$repo#nixosConfigurations.$host.config" --apply '
    c:
    let
      has = s: sub: builtins.match (".*" + sub + ".*") s != null;
      b = x: if x then "yes" else "no";
      ms = c.services.mediaServer;
      mon = c.services.monitoring;
      nvidia = ms.gpu == "nvidia";
      epg = ms.liveSportsEpg.enable && ms.liveSportsEpg.listenPort > 0;
      disp = ms.dispatcharr.enable;
      deadman = mon.enableDeadManSwitch && mon.deadManURL != "";
      jobs = builtins.toJSON (map (s: s.job_name) c.services.prometheus.scrapeConfigs);
      rules = builtins.toJSON c.services.grafana.provision.alerting.rules.settings;
      svc = c.systemd.services;
      tim = c.systemd.timers;
      row = name: want: got: "${name}\t${b want}\t${b got}\n";
    in
      row "dispatcharr probe"        disp    (has jobs "\"dispatcharr\"")
      + row "dispatcharr alert"      disp    (has rules "\"uid\":\"dispatcharr-down\"")
      + row "live-sports-epg probe"  epg     (has jobs "\"live-sports-epg\"")
      + row "live-sports-epg alert"  epg     (has rules "\"uid\":\"live-sports-epg-down\"")
      + row "nvidia check service"   nvidia  (svc ? "nvidia-driver-check")
      + row "nvidia check timer"     nvidia  (tim ? "nvidia-driver-check")
      + row "nvidia alert"           nvidia  (has rules "\"uid\":\"nvidia-driver-mismatch\"")
      + row "deadman-ping service"   deadman (svc ? "deadman-ping")
      + row "deadman-ping timer"     deadman (tim ? "deadman-ping")
  ' 2>/dev/null)"

  while IFS=$'\t' read -r name want got; do
    [ -n "$name" ] || continue
    printf '%-8s %-24s want=%-3s got=%-3s ' "$host" "$name" "$want" "$got"
    if [ "$want" = "$got" ]; then echo ok; else echo FAIL; fail=1; fi
  done <<<"$lines"
done

exit "$fail"
