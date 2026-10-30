#!/usr/bin/env bash
#
# Assert the evaluated NixOS configs expose the new probes, alerts, and timers
# on the hosts that should have them, and omit them everywhere else.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0

check() {
  local host="$1" attr="$2" needle="$3" want="$4"
  local json
  json="$(nix eval --json "$repo#nixosConfigurations.$host.config.$attr" 2>/dev/null)"
  if grep -q "$needle" <<<"$json"; then found=yes; else found=no; fi
  printf '%-8s %-45s %-22s want=%-3s got=%-3s ' "$host" "$attr" "$needle" "$want" "$found"
  if [ "$found" = "$want" ]; then echo ok; else echo FAIL; fail=1; fi
}

has_attr() {
  local host="$1" attr="$2" want="$3" got
  got="$(nix eval --json "$repo#nixosConfigurations.$host.config.$attr" \
    --apply 'x: builtins.hasAttr "nvidia-driver-check" x' 2>/dev/null)"
  [ "$got" = true ] && got=yes || got=no
  printf '%-8s %-45s %-22s want=%-3s got=%-3s ' "$host" "$attr" "nvidia-driver-check" "$want" "$got"
  if [ "$got" = "$want" ]; then echo ok; else echo FAIL; fail=1; fi
}

check P27691 services.prometheus.scrapeConfigs '"job_name":"dispatcharr"' yes
check P27691 services.prometheus.scrapeConfigs '"job_name":"live-sports-epg"' yes
check P22725 services.prometheus.scrapeConfigs '"job_name":"dispatcharr"' no
check P22725 services.prometheus.scrapeConfigs '"job_name":"live-sports-epg"' no
check T29769 services.prometheus.scrapeConfigs '"job_name":"dispatcharr"' no
check T29769 services.prometheus.scrapeConfigs '"job_name":"live-sports-epg"' no

check P27691 services.grafana.provision.alerting.rules.settings '"uid":"dispatcharr-down"' yes
check P27691 services.grafana.provision.alerting.rules.settings '"uid":"live-sports-epg-down"' yes
check P27691 services.grafana.provision.alerting.rules.settings '"uid":"nvidia-driver-mismatch"' yes
check P22725 services.grafana.provision.alerting.rules.settings '"uid":"live-sports-epg-down"' no
check T29769 services.grafana.provision.alerting.rules.settings '"uid":"dispatcharr-down"' no
check T29769 services.grafana.provision.alerting.rules.settings '"uid":"live-sports-epg-down"' no
check T29769 services.grafana.provision.alerting.rules.settings '"uid":"nvidia-driver-mismatch"' no

has_attr P27691 systemd.services yes
has_attr P27691 systemd.timers yes
has_attr T29769 systemd.services no
has_attr T29769 systemd.timers no

exit "$fail"
