'use strict';

import { normalizeTeamName, splitVariant, splitTeams, stripNoise } from './normalize.js';
import { ALIASES } from './aliases.js';

/**
 * Build a reverse-lookup index from every alias (incl. canonical key) → canonical key.
 * Done once at module load for O(1) alias lookups.
 */
function buildIndex() {
  const idx = new Map();
  for (const [canonical, aliases] of Object.entries(ALIASES)) {
    const c = normalizeTeamName(canonical);
    idx.set(c, c);
    for (const a of aliases) {
      const n = normalizeTeamName(a);
      if (!idx.has(n)) idx.set(n, c);
    }
  }
  return idx;
}

const ALIAS_INDEX = buildIndex();

/**
 * Resolve a team name (in any form the M3U might use) to its canonical key.
 * Returns the input if no alias matches — this is *not* a hard error, just means
 * we don't have a curated alias for this team yet.
 */
export function resolveCanonical(name) {
  if (!name) return '';
  const direct = normalizeTeamName(stripNoise(name));
  if (ALIAS_INDEX.has(direct)) return ALIAS_INDEX.get(direct);

  // Word-subset fallback: "New York Yankees" → "yankees" → "new york yankees".
  // Require every word of the *shorter* side to appear as a whole word in
  // the *longer* side — a plain substring/prefix check is too permissive
  // (e.g. the 2-letter token "st" is a prefix of "st louis cardinals" and
  // would wrongly match any name containing the word "st").
  const directTokens = direct.split(' ').filter(Boolean);
  for (const [needle, canonical] of ALIAS_INDEX) {
    const needleTokens = needle.split(' ').filter(Boolean);
    const [smaller, larger] = needleTokens.length <= directTokens.length
      ? [needleTokens, directTokens]
      : [directTokens, needleTokens];
    if (smaller.length === 0) continue;
    if (smaller.every((t) => larger.includes(t))) return canonical;
  }
  return direct; // unknown team — return normalized form so logs are useful
}

/**
 * Lightweight structural similarity score between two normalized names.
 * Returns a number in [0, 1]. Used as a tiebreaker when both candidates
 * share a known alias.
 */
function similarity(a, b) {
  if (!a || !b) return 0;
  if (a === b) return 1;
  if (a.includes(b) || b.includes(a)) {
    const shorter = a.length < b.length ? a : b;
    return 0.7 + 0.3 * (shorter.length / Math.max(a.length, b.length));
  }
  // Jaccard over words
  const wa = new Set(a.split(' '));
  const wb = new Set(b.split(' '));
  const inter = [...wa].filter((w) => wb.has(w)).length;
  const union = new Set([...wa, ...wb]).size || 1;
  return inter / union;
}

/**
 * Match a single live-game stream (tvgId) against an array of schedule events.
 * Each event is { id, sport, league, startTime, endTime, away: { name, ... },
 *                  home: { name, ... }, venue, status, ... }.
 *
 * Returns:
 *   { matched: true, event, confidence, reason }
 *   { matched: false, reason }   ← never throws
 *
 * Confidence is in [0, 1]. Anything ≥ 0.7 is considered a real match;
 * 0.5–0.7 is a soft match; < 0.5 is no match.
 */
export function matchStream(tvgId, events) {
  const reason = { tvgId };
  if (!tvgId) return { matched: false, reason: { ...reason, error: 'empty tvgId' } };
  if (!Array.isArray(events) || events.length === 0) {
    return { matched: false, reason: { ...reason, error: 'no events to match against' } };
  }

  const { variant, event: eventPart } = splitVariant(tvgId);
  const [awayRaw, homeRaw] = splitTeams(eventPart);
  if (!awayRaw || !homeRaw) {
    return { matched: false, reason: { ...reason, error: 'could not split teams' } };
  }

  const awayCanon = resolveCanonical(awayRaw);
  const homeCanon = resolveCanonical(homeRaw);

  let best = null;
  for (const ev of events) {
    const evAway = resolveCanonical(ev.away?.name || '');
    const evHome = resolveCanonical(ev.home?.name || '');

    // A match requires the *pair* to align. Allow swap so a home/away
    // mismatch doesn't kill the match (some providers label differently).
    const sameSide = awayCanon === evAway && homeCanon === evHome;
    const swapped = awayCanon === evHome && homeCanon === evAway;
    if (!sameSide && !swapped) continue;

    const awayScore = similarity(awayCanon, evAway);
    const homeScore = similarity(homeCanon, evHome);
    const score = (awayScore + homeScore) / 2;
    if (!best || score > best.confidence) {
      best = { event: ev, confidence: score, swapped, reason: { awayCanon, homeCanon } };
    }
  }

  if (!best) {
    return { matched: false, reason: { ...reason, awayCanon, homeCanon, error: 'no candidate' } };
  }
  return {
    matched: true,
    event: best.event,
    confidence: best.confidence,
    variant,
    swapped: best.swapped,
    reason: { ...best.reason, tvgId },
  };
}

export { ALIAS_INDEX };
