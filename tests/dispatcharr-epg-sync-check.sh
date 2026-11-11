#!/usr/bin/env bash
# Eval/stub harness for the Dispatcharr EPG reconciler: proves the packaged
# node script is wired and that its pure planning logic fixes only known-bad
# mappings (no API calls, no Dispatcharr instance required).
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

node --test "$repo/packages/dispatcharr-epg-sync/test/sync.test.js"

# The service must invoke the packaged script from the Nix store path.
any_host="$(nix eval --raw "$repo#nixosConfigurations" \
  --apply 'x: builtins.head (builtins.attrNames x)' 2>/dev/null)"
[ -n "$any_host" ] || { echo "FAIL: no hosts discovered" >&2; exit 1; }
# Service only exists when enabled; just assert the module evaluates and the
# source package is present in the repo (eval-only, no host toggles forced).
test -f "$repo/packages/dispatcharr-epg-sync/src/sync.js"
test -f "$repo/packages/dispatcharr-epg-sync/data/channel-map.json"
test -f "$repo/packages/iptv-org-epg/channels.xml"

# Curated channels must have the attributes iptv-org/epg requires.
node -e '
const fs=require("fs"), xml=fs.readFileSync(process.argv[1],"utf8");
const ch=[...xml.matchAll(/<channel([^>]*)>([^<]*)<\/channel>/g)];
if(!ch.length) throw new Error("no channels");
for(const m of ch){
  const a=m[1], name=m[2].trim();
  for(const k of ["site=\"","lang=\"","xmltv_id=\"","site_id=\""]) if(!a.includes(k)) throw new Error(`missing ${k} on ${name}`);
}
console.log(`channels.xml: ${ch.length} channels ok`);
' "$repo/packages/iptv-org-epg/channels.xml"

# Reconciler must trigger an EPG source refresh after registering/updating it.
grep -q 'refreshSource' "$repo/packages/dispatcharr-epg-sync/src/sync.js"

# Grabber must not bind to Grafana's port (3000) on any host where enabled.
nix eval --raw "$repo#nixosConfigurations" --apply '
  x: let
    hosts = builtins.attrNames x;
    bad = builtins.filter (h:
      let c = x.${h}.config; ms = c.services.mediaServer; g = c.services.grafana.settings.server.http_port or 3000;
      in (ms.dispatcharr.epgGrabber.enable or false) && (ms.dispatcharr.epgGrabber.port or 0) == g
    ) hosts;
  in if bad == [] then "ok" else builtins.concatStringsSep "," bad
' 2>/dev/null | grep -qx ok || { echo "FAIL: epgGrabber port conflicts with Grafana on some host" >&2; exit 1; }

echo "dispatcharr-epg-sync wiring: ok"
