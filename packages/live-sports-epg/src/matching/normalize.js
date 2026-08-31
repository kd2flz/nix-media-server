'use strict';

/**
 * Normalize a team name for fuzzy matching:
 *  - lowercase
 *  - strip diacritics
 *  - collapse whitespace
 *  - strip common punctuation (keep hyphens inside words)
 *  - expand a few common abbreviations
 *
 * The result is used as the *key* for alias lookup, never the display name.
 */
export function normalizeTeamName(name) {
  if (!name) return '';
  return String(name)
    .toLowerCase()
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '') // strip diacritics
    .replace(/[.']/g, '')            // drop periods and apostrophes
    .replace(/\s+/g, ' ')
    .replace(/&/g, 'and')
    .trim();
}

/**
 * Extract a stream variant suffix from a tvg-id.
 * Returns the canonical variant token ('A', 'H', or null) and the
 * remaining event portion with the suffix removed.
 *
 *   "Reds @ Cubs-A"   → { variant: 'A', event: 'Reds @ Cubs' }
 *   "Reds @ Cubs - H" → { variant: 'H', event: 'Reds @ Cubs' }
 *   "Reds @ Cubs"     → { variant: null, event: 'Reds @ Cubs' }
 */
export function splitVariant(tvgId) {
  if (!tvgId) return { variant: null, event: tvgId };
  // Match a trailing -A/-H or ' A'/' H' (case-insensitive). Allow optional space.
  const m = tvgId.match(/^(.*?)(?:\s*[- ]\s*([AH]))\s*$/i);
  if (!m) return { variant: null, event: tvgId };
  return { variant: m[2].toUpperCase(), event: m[1].trim() };
}

/**
 * Split an event portion into [away, home] teams. Supports a few separators
 * so the matcher isn't married to ' @ ':
 *   "Reds @ Cubs"        → ['Reds', 'Cubs']
 *   "Reds vs. Cubs"       → ['Reds', 'Cubs']
 *   "Reds at Cubs"        → ['Reds', 'Cubs']
 *   "Reds/Cubs"           → ['Reds', 'Cubs']
 */
export function splitTeams(eventName) {
  if (!eventName) return [null, null];
  // Order matters: try the longer/more-specific patterns first.
  const patterns = [
    /^(.+?)\s+(?:@|vs\.?|versus|at|v)\s+(.+)$/i,
    /^(.+?)\s*\/\s*(.+)$/i,
  ];
  for (const re of patterns) {
    const m = eventName.match(re);
    if (m) return [m[1].trim(), m[2].trim()];
  }
  return [eventName.trim(), null];
}

/**
 * Strip common sports prefixes/suffixes that providers bolt onto names.
 *   "Boston Red Sox"        → "Boston Red Sox"  (kept)
 *   "Boston Red Sox MLB"    → "Boston Red Sox"
 *   "Manchester United FC"  → "Manchester United"
 */
export function stripNoise(name) {
  if (!name) return '';
  return String(name)
    .replace(/\b(mlb|nfl|nba|nhl|epl|fc|cf|afc|nfc|sc|as|sporting|soccer)\b/gi, '')
    .replace(/\b(united states|usa|u\.s\.a\.?|uk)\b/gi, '')
    .replace(/\s+/g, ' ')
    .trim();
}
