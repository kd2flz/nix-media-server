#!/usr/bin/env bash
#
# Regression test for scripts/change-impact.sh: compare from the merge base of
# the PR, not from the base branch tip. A base-branch-only commit (e.g. a
# main-only hotfix that was never merged back into dev) must not show up as a
# reversion introduced by the PR.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Build a throwaway repo with the shape that triggered the false positive:
#   main: C0 (unchanged) -> C1 (unit changed, never merged back)
#   dev:  C0 -> C2 (docs only) -> C3 (unit changed)
git init -q -b main "$tmp/repo"
git -C "$tmp/repo" config user.email test@example.com
git -C "$tmp/repo" config user.name test
printf 'base\n' > "$tmp/repo/file"
git -C "$tmp/repo" add file
git -C "$tmp/repo" commit -qm C0

git -C "$tmp/repo" checkout -q -b dev
printf 'docs\n' >> "$tmp/repo/file"
git -C "$tmp/repo" commit -qam C2
dev_docs="$(git -C "$tmp/repo" rev-parse dev)"

printf 'dev unit change\n' >> "$tmp/repo/file"
git -C "$tmp/repo" commit -qam C3
dev_changed="$(git -C "$tmp/repo" rev-parse dev)"

git -C "$tmp/repo" checkout -q main
printf 'main-only unit change\n' > "$tmp/repo/file"
git -C "$tmp/repo" commit -qam C1
main_tip="$(git -C "$tmp/repo" rev-parse main)"
merge_base="$(git -C "$tmp/repo" merge-base main dev)"

# Stub nix. The synthetic unit differs only at $CHANGED_REV, mirroring a real
# unit change; every other revision is identical. No Nix evaluation happens.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/nix" <<'EOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *".config"*)
    rev="$(sed -n 's/.*?rev=\([^#]*\)#.*/\1/p' <<<"$args" | head -n1)"
    if [ "$rev" = "${CHANGED_REV:?CHANGED_REV is required}" ]; then
      path=/nix/store/changed-caddy
    else
      path=/nix/store/unchanged-caddy
    fi
    printf 'unit\tcaddy.service\t%s\n' "$path"
    printf 'unit\tpodman-open-webui.service\t%s\n' "$path"
    ;;
  *) printf 'HOST' ;;
esac
EOF
chmod +x "$tmp/bin/nix"

run_impact() {
  local base="$1" head="$2" changed="$3"
  CHANGE_IMPACT_REPO="$tmp/repo" CHANGED_REV="$changed" PATH="$tmp/bin:$PATH" \
    bash "$repo/scripts/change-impact.sh" "$base" "$head"
}

# Scenario 1: dev -> main with no functional change. The main-only C1 must be
# ignored; comparing tips would invent two restarted units.
out="$(run_impact "$main_tip" "$dev_docs" "$main_tip")"
grep -q "Deploy impact: \`${merge_base:0:7}\` -> \`${dev_docs:0:7}\`" <<<"$out" || {
  echo 'FAIL: report did not compare from the merge base' >&2
  echo "$out" >&2
  exit 1
}
grep -q '### HOST: no change' <<<"$out" || {
  echo 'FAIL: docs-only PR reported a change' >&2
  echo "$out" >&2
  exit 1
}
if grep -q 'systemd unit' <<<"$out"; then
  echo 'FAIL: main-only commit was reported as a systemd restart' >&2
  echo "$out" >&2
  exit 1
fi
echo 'base-branch-only commit ignored: ok'

# Scenario 2: a real unit change on the head branch is still reported.
out="$(run_impact "$main_tip" "$dev_changed" "$dev_changed")"
grep -q '### HOST: no reboot' <<<"$out" || {
  echo 'FAIL: real unit change not reported' >&2
  echo "$out" >&2
  exit 1
}
grep -q '2 systemd unit(s) change' <<<"$out" || {
  echo 'FAIL: real unit change count wrong' >&2
  echo "$out" >&2
  exit 1
}
grep -q '`caddy.service`' <<<"$out" || {
  echo 'FAIL: changed unit not listed' >&2
  echo "$out" >&2
  exit 1
}
echo 'real unit change still reported: ok'

echo 'all change-impact-check cases passed'
