#!/usr/bin/env bash
#
# Report what a change will do to each host when it deploys, by comparing the
# evaluated configs at two git revisions (eval only, nothing is built).
#
#   scripts/change-impact.sh <base-rev> <head-rev>   (default: origin/main HEAD)
#
# Writes a Markdown report to stdout. Exit codes:
#   0  no reboot-class change
#   2  at least one host needs a reboot (kernel, initrd, kernel modules, NVIDIA)
# Service restarts and secrets changes are warnings only and never change the
# exit code.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
base="$(git -C "$repo" rev-parse "${1:-origin/main}")"
head="$(git -C "$repo" rev-parse "${2:-HEAD}")"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

flake() { printf 'git+file://%s?rev=%s' "$repo" "$1"; }

hosts="$(nix eval --raw "$(flake "$head")#nixosConfigurations" --apply 'x: builtins.concatStringsSep " " (builtins.attrNames x)' 2>/dev/null)"

# One "key<TAB>store path" line per boot-critical component or systemd unit.
snapshot() {
  local rev="$1" host="$2"
  nix eval --raw "$(flake "$rev")#nixosConfigurations.$host.config" --apply '
    c:
    let
      try = e: let r = builtins.tryEval e; in if r.success then r.value else "none";
      boot = {
        "kernel" = try c.boot.kernelPackages.kernel.outPath;
        "initrd" = try c.system.build.initialRamdisk.outPath;
        "kernel-modules" = try c.system.modulesTree.outPath;
        "nvidia-userspace" = if (c.services.mediaServer.gpu or "none") == "nvidia" then try c.hardware.nvidia.package.outPath else "n/a";
      };
      units = builtins.mapAttrs (_: u: try u.unit.outPath) c.systemd.units;
      line = p: k: v: "${p}\t${k}\t${v}\n";
    in
      builtins.concatStringsSep ""
        ((builtins.attrValues (builtins.mapAttrs (line "boot") boot))
         ++ (builtins.attrValues (builtins.mapAttrs (line "unit") units)))
  ' | sort
}

reboot_hosts=0
{
  echo "## Deploy impact: \`${base:0:7}\` -> \`${head:0:7}\`"
  echo
  for host in $hosts; do
    if ! snapshot "$base" "$host" > "$tmp/$host.base" 2>/dev/null; then
      echo "### $host: not evaluable at base (new host?), skipped"
      echo
      continue
    fi
    snapshot "$head" "$host" > "$tmp/$host.head"

    boot_changed="$(join -t $'\t' -j1 \
      <(awk -F'\t' '$1=="boot"{print $2"\t"$3}' "$tmp/$host.base") \
      <(awk -F'\t' '$1=="boot"{print $2"\t"$3}' "$tmp/$host.head") \
      | awk -F'\t' '$2!=$3{print $1}')"

    # Units whose file changed, were added, or were removed.
    unit_changed="$({ diff <(awk -F'\t' '$1=="unit"{print $2"\t"$3}' "$tmp/$host.base") \
                         <(awk -F'\t' '$1=="unit"{print $2"\t"$3}' "$tmp/$host.head") \
      | awk -F'\t' '/^[<>]/{sub(/^[<>] /,""); print $1}' | sort -u; } || true)"

    if [ -n "$boot_changed" ]; then
      reboot_hosts=$((reboot_hosts + 1))
      echo "### $host: REBOOT REQUIRED"
      echo
      echo "Changed boot-critical components: $(echo "$boot_changed" | paste -sd, - | sed 's/,/, /g')."
      echo "nixos-auto-reboot will schedule a reboot in the 03:00-05:00 window."
      echo
    elif [ -z "$unit_changed" ]; then
      echo "### $host: no change"
      echo
      continue
    else
      echo "### $host: no reboot"
      echo
    fi
    if [ -n "$unit_changed" ]; then
      echo "<details><summary>$(echo "$unit_changed" | wc -l) systemd unit(s) change (restart on switch)</summary>"
      echo
      echo "$unit_changed" | sed 's/^/- `/; s/$/`/'
      echo
      echo "</details>"
      echo
    fi
  done

  secrets="$(git -C "$repo" diff --name-only "$base" "$head" -- .sops.yaml secrets/)"
  if [ -n "$secrets" ]; then
    echo "### Warning: secrets/host-key files changed"
    echo
    echo "$secrets" | sed 's/^/- `/; s/$/`/'
    echo
    echo "Confirm every affected host can still decrypt (\`sops updatekeys\` run, host keys present)."
    echo
  fi

  if [ "$reboot_hosts" -gt 0 ]; then
    echo "**$reboot_hosts host(s) will reboot. Hold this merge until a maintenance window, then add the \`approved-for-downtime\` label.**"
  else
    echo "No reboot-class changes."
  fi
}

[ "$reboot_hosts" -gt 0 ] && exit 2
exit 0
