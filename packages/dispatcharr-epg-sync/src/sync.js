#!/usr/bin/env node
// Reconciles Dispatcharr channel EPG mappings against curated xmltv_ids and
// fixes known bad epg_data_id assignments. Declarative/idempotent: only
// channels that differ from the desired mapping are updated.

import fs from 'node:fs/promises';

function env(name, fallback = undefined) {
  const v = process.env[name];
  return v === undefined || v === '' ? fallback : v;
}

export function planFixes(channels, epgData, fixes) {
  const epgByTvg = new Map();
  for (const e of epgData) if (e && e.tvg_id != null) epgByTvg.set(String(e.tvg_id), e);
  const chanByName = new Map();
  for (const c of channels) if (c && c.name != null) chanByName.set(String(c.name), c);

  const planned = [];
  const missing = [];
  for (const fix of fixes || []) {
    const chan = chanByName.get(fix.channelName);
    if (!chan) { missing.push({ ...fix, reasonMissing: 'channel not found' }); continue; }
    const epg = epgByTvg.get(fix.xmltvId);
    if (!epg) { missing.push({ ...fix, reasonMissing: `epg_data tvg_id ${fix.xmltvId} not found` }); continue; }
    if (chan.epg_data_id !== epg.id) {
      planned.push({ channelId: chan.id, channelName: chan.name, from: chan.epg_data_id, to: epg.id, xmltvId: fix.xmltvId, reason: fix.reason });
    }
  }
  return { planned, missing };
}

async function apiFetch(base, key, path, init = {}) {
  const res = await fetch(`${base}${path}`, {
    ...init,
    headers: { 'X-API-Key': key, 'Content-Type': 'application/json', ...(init.headers || {}) },
  });
  if (!res.ok) throw new Error(`${path} -> ${res.status} ${await res.text()}`);
  const ct = res.headers.get('content-type') || '';
  return ct.includes('json') ? res.json() : res.text();
}

async function loadAll(base, key, path) {
  // Dispatcharr list endpoints may paginate (count/results) or return arrays.
  const first = await apiFetch(base, key, path);
  if (Array.isArray(first)) return first;
  const results = [...(first.results || [])];
  let next = first.next;
  while (next) {
    const url = next.startsWith('http') ? next : `${base}${next}`;
    const res = await fetch(url, { headers: { 'X-API-Key': key } });
    if (!res.ok) throw new Error(`page ${next} -> ${res.status}`);
    const page = await res.json();
    results.push(...(page.results || []));
    next = page.next;
  }
  return results;
}

async function ensureSource(base, key, name, url) {
  if (!name || !url) return;
  const sources = await loadAll(base, key, '/api/epg/sources/');
  const existing = sources.find((s) => s && s.name === name);
  const payload = { name, source_type: 'xmltv', url, is_active: true };
  if (existing) {
    if (existing.url !== url || existing.source_type !== 'xmltv') {
      await apiFetch(base, key, `/api/epg/sources/${existing.id}/`, { method: 'PATCH', body: JSON.stringify(payload) });
      console.log(`dispatcharr-epg-sync: updated EPG source ${name}`);
    }
    return;
  }
  await apiFetch(base, key, '/api/epg/sources/', { method: 'POST', body: JSON.stringify(payload) });
  console.log(`dispatcharr-epg-sync: created EPG source ${name}`);
}

async function main() {
  const base = (env('DISPATCHARR_URL', 'http://127.0.0.1:9191') || '').replace(/\/$/, '');
  const keyFile = env('DISPATCHARR_API_KEY_FILE');
  const mapFile = env('CHANNEL_MAP_FILE');
  const sourceName = env('EPG_SOURCE_NAME', 'local-guide');
  const sourceUrl = env('EPG_SOURCE_URL', '');
  const dryRun = env('DRY_RUN', '0') === '1';
  if (!keyFile || !mapFile) throw new Error('DISPATCHARR_API_KEY_FILE and CHANNEL_MAP_FILE are required');
  const key = (await fs.readFile(keyFile, 'utf8')).trim();
  const map = JSON.parse(await fs.readFile(mapFile, 'utf8'));

  await ensureSource(base, key, sourceName, sourceUrl);

  const [channels, epgData] = await Promise.all([
    loadAll(base, key, '/api/channels/channels/'),
    loadAll(base, key, '/api/epg/epgdata/'),
  ]);
  const { planned, missing } = planFixes(channels, epgData, map.fixes || []);
  for (const m of missing) console.warn(`skip: ${m.channelName || m.xmltvId} (${m.reasonMissing})`);
  if (planned.length === 0) { console.log('dispatcharr-epg-sync: no changes'); return; }

  for (const p of planned) {
    console.log(`${dryRun ? 'would fix' : 'fix'}: ${p.channelName} (${p.channelId}) ${p.from} -> ${p.to} [${p.xmltvId}] ${p.reason}`);
    if (!dryRun) {
      await apiFetch(base, key, `/api/channels/channels/${p.channelId}/`, {
        method: 'PATCH',
        body: JSON.stringify({ epg_data_id: p.to }),
      });
    }
  }
  console.log(`dispatcharr-epg-sync: ${planned.length} change(s)${dryRun ? ' (dry-run)' : ''}`);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((e) => { console.error(e.stack || e.message); process.exit(1); });
}
