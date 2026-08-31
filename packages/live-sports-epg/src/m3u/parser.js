'use strict';

/**
 * Parse a single #EXTINF line into its attributes and the channel name.
 * Returns null if the line isn't an EXTINF.
 *
 * Example:
 *   #EXTINF:0 tvg-id="Reds @ Cubs-A" tvg-logo="https://..." group-title="Live-Games",Reds @ Cubs-A
 *   → { tvgId: 'Reds @ Cubs-A', tvgLogo: 'https://...', groupTitle: 'Live-Games', name: 'Reds @ Cubs-A' }
 */
export function parseExtinf(line) {
  if (!line || !line.startsWith('#EXTINF')) return null;

  // Strip the prefix up to the first comma — everything before is the attribute block,
  // everything after is the channel display name.
  const commaIdx = line.indexOf(',');
  if (commaIdx < 0) return null;

  const attrBlock = line.slice(0, commaIdx);
  const name = line.slice(commaIdx + 1).trim();

  const out = { name };
  // Pull every k="v" pair out of the attribute block. Values may be quoted with ".
  const attrRegex = /([a-zA-Z0-9_-]+)="([^"]*)"/g;
  let m;
  while ((m = attrRegex.exec(attrBlock)) !== null) {
    const key = m[1].toLowerCase();
    const val = m[2];
    if (key === 'tvg-id') out.tvgId = val;
    else if (key === 'tvg-logo') out.tvgLogo = val;
    else if (key === 'group-title') out.groupTitle = val;
    else if (key === 'tvg-name') out.tvgName = val;
    else if (key === 'tvg-shift') out.tvgShift = val;
  }
  return out;
}

/**
 * Parse a full M3U document into a list of entries.
 * Each entry has: { tvgId, tvgLogo, groupTitle, name, url }
 *
 * Tolerant: skips malformed lines, never throws on a single bad entry.
 */
export function parseM3U(text) {
  if (typeof text !== 'string' || text.length === 0) return [];

  const lines = text.split(/\r?\n/);
  const entries = [];
  let pending = null;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line) continue;

    if (line.startsWith('#EXTM3U')) continue;

    if (line.startsWith('#EXTINF')) {
      const parsed = parseExtinf(line);
      pending = parsed ? { ...parsed, url: null } : null;
      continue;
    }

    if (line.startsWith('#')) continue; // unknown directive, ignore

    if (pending) {
      pending.url = line;
      // Use tvgId when present, otherwise fall back to name. Strip whitespace.
      pending.tvgId = (pending.tvgId || pending.name || '').trim();
      pending.name = (pending.name || pending.tvgId || '').trim();
      entries.push(pending);
      pending = null;
    }
    // Lines without a preceding EXTINF are silently dropped — that's a malformed M3U.
  }

  return entries;
}

/**
 * Filter M3U entries to only those that look like live-game streams.
 * Heuristic: entries with a `Live-Games` group title, OR entries whose tvg-id
 * matches the common `<TeamA> @ <TeamB>[-A|-H]` pattern when no group filter is set.
 */
export function filterLiveGameEntries(entries, { groupTitle = 'Live-Games' } = {}) {
  return entries.filter((e) => {
    if (!e.tvgId) return false;
    if (e.groupTitle && e.groupTitle === groupTitle) return true;
    // Fall back: anything with a " @ " separator and -A/-H suffix is almost
    // certainly a live-game stream even if the group title is missing.
    if (e.tvgId.includes(' @ ') && /[- ]?(A|H)$/i.test(e.tvgId)) return true;
    return false;
  });
}
