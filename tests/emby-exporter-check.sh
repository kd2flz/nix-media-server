#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

host="$(nix eval --raw "$repo#nixosConfigurations" --apply '
  x: builtins.concatStringsSep " "
    (builtins.filter (h:
      x.${h}.config.services.mediaServer.emby.enable
      && x.${h}.config.services.mediaServer.emby.apiKeyFile != null
    ) (builtins.attrNames x))
' 2>/dev/null | awk '{print $1}')"
if [ -z "$host" ]; then
  echo 'no host enables the Emby exporter; nothing to test'
  exit 0
fi

exec_start="$(nix eval --raw "$repo#nixosConfigurations.$host.config.systemd.services.emby-exporter.serviceConfig.ExecStart")"
grep -q 'emby-exporter.py' <<<"$exec_start" || {
  echo 'FAIL: emby-exporter unit does not use the tracked script' >&2
  exit 1
}

printf 'secret\n' > "$tmp/apikey"
export EMBY_API_KEY_FILE="$tmp/apikey"

if command -v python3 >/dev/null 2>&1; then
  py=(python3)
else
  py=(nix run nixpkgs#python3 --)
fi

"${py[@]}" - "$repo/packages/emby-exporter/emby-exporter.py" <<'PY'
import importlib.util
import sys

path = sys.argv[1]
spec = importlib.util.spec_from_file_location("emby_exporter", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

session = {
    "UserName": 'A "quoted" \\ back\nnext',
    "DeviceName": "dev\\ice",
    "Client": "Chrome",
    "DeviceId": "device-1",
    "NowPlayingItem": {"Name": "Episode"},
    "TranscodingInfo": {
        "HardwareDecoding": "None",
        "IsVideoDirectEncode": False,
    },
}
module.fetch = lambda: [session]
module.poll()
out = module.render()

assert "emby_sessions_transcoding 1" in out, "aggregate transcoding count should be 1"
assert 'transcoding="1"' in out, "per-session transcoding label should be 1"
assert 'hwd="0"' in out, "hardware decode label should be 0"
assert 'hwe="1"' in out, "hardware encode label should be 1"

info_lines = [line for line in out.splitlines() if line.startswith("emby_session_info")]
assert len(info_lines) == 1, "label values should not inject extra metric lines"
assert 'user="A \\"quoted\\" \\\\ back\\nnext"' in info_lines[0], "label quoting/escaping is wrong"
assert 'device="dev\\\\ice"' in info_lines[0], "backslash escaping is wrong"

print("emby-exporter checks passed")
PY
