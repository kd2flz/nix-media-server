#!/usr/bin/env bash
#
# Exercise the nixos-auto-reboot shell logic without rebooting anything.
#
# The real script compares /run/booted-system with /run/current-system. This
# harness substitutes temp directories, a controllable `date`, and stubs for
# `wall`/`shutdown`, then checks each branch (equal, changed, in/out of the
# 03:00-05:00 window).
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin"
cat > "$tmp/bin/date" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${HOUR:?HOUR is required}"
EOF
cat > "$tmp/bin/wall" <<'EOF'
#!/usr/bin/env bash
printf 'wall %s\n' "$*" >> "${CALLS:?CALLS is required}"
EOF
cat > "$tmp/bin/shutdown" <<'EOF'
#!/usr/bin/env bash
printf 'shutdown %s\n' "$*" >> "${CALLS:?CALLS is required}"
EOF
chmod +x "$tmp/bin/"*

hosts="$(nix eval --raw "$repo#nixosConfigurations" --apply 'x: builtins.concatStringsSep " " (builtins.attrNames x)' 2>/dev/null)"
host="${hosts%% *}"   # the script comes from modules/common.nix, so any host works
real_script="$(nix eval --raw "$repo#nixosConfigurations.$host.config.systemd.services.nixos-auto-reboot.script")"
grep -q '/run/current-system' <<<"$real_script" || {
  echo 'FAIL: generated script does not compare against /run/current-system' >&2
  exit 1
}
grep -q '/bin/wall' <<<"$real_script" || {
  echo 'FAIL: generated script does not call wall' >&2
  exit 1
}

script="$tmp/script.sh"
perl -pe '
  s#/run/booted-system#'"$tmp"'/booted#g;
  s#/run/current-system#'"$tmp"'/current#g;
  s#/nix/store/[^/]+-coreutils[^/]+/bin/date#'"$tmp"'/bin/date#g;
  s#/nix/store/[^/]+-util-linux[^/]+/bin/wall#'"$tmp"'/bin/wall#g;
  s#/nix/store/[^/]+-systemd[^/]+/bin/shutdown#'"$tmp"'/bin/shutdown#g;
  s#/nix/store/[^/]+-coreutils[^/]+/bin/(\w+)#$1#g;
' <<<"$real_script" > "$script"
chmod +x "$script"

# Any other store path would not exist on a clean CI runner; fail loudly.
if grep -q '/nix/store/' "$script"; then
  echo 'FAIL: unstubbed /nix/store path left in script:' >&2
  grep -n '/nix/store/' "$script" >&2
  exit 1
fi

set_links() {
  local booted="$1" current="$2"
  rm -rf "$tmp/booted" "$tmp/current"
  mkdir -p "$tmp/booted" "$tmp/current"
  for f in initrd kernel kernel-modules; do
    ln -s "$booted-$f" "$tmp/booted/$f"
    ln -s "$current-$f" "$tmp/current/$f"
  done
}

run_case() {
  local name="$1" hour="$2" expect="$3"
  export HOUR="$hour" CALLS="$tmp/calls"
  : > "$CALLS"
  local out
  out="$(bash "$script")"
  printf '%-42s ' "$name"
  case "$expect" in
    no-reboot)
      grep -q 'no reboot needed' <<<"$out"
      test ! -s "$CALLS"
      echo 'ok (no reboot)'
      ;;
    outside)
      grep -q 'Outside maintenance window' <<<"$out"
      test ! -s "$CALLS"
      echo 'ok (outside window)'
      ;;
    reboot)
      grep -q 'Rebooting in 1 minute' <<<"$out"
      grep -q '^wall ' "$CALLS"
      grep -q '^shutdown -r +1 ' "$CALLS"
      echo 'ok (reboot scheduled)'
      ;;
    *) echo "unknown expectation $expect" >&2; exit 1 ;;
  esac
}

set_links a a
run_case 'same kernel' 08 no-reboot

set_links a b
run_case 'changed kernel, 03:00' 03 reboot
run_case 'changed kernel, 04:59' 04 reboot
run_case 'changed kernel, 02:59' 02 outside
run_case 'changed kernel, 05:00' 05 outside
run_case 'changed kernel, 08:00' 08 outside

rm -rf "$tmp/booted" "$tmp/current"
mkdir -p "$tmp/booted" "$tmp/current"
run_case 'missing boot-critical paths' 03 no-reboot

echo 'all reboot-check cases passed'
