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
 * Some providers shorten team names to a single, ambiguous word ("York",
 * "Angeles", "Bay"). Global alias resolution picks one fixed team for these,
 * often from the wrong sport, so also accept a side whose words all appear in
 * the event team's full name — the pairing with the other side disambiguates.
 */
const PARTIAL_SCORE = 0.6;
function tokens(name) {
  return normalizeTeamName(stripNoise(name)).split(' ').filter(Boolean);
}
function partialSide(rawTokens, evName) {
  if (rawTokens.length === 0) return false;
  // A lone two-letter token ("LA", "NY") is too ambiguous to match on its own.
  // Multi-word names can keep short tokens ("UT Rio Grande Valley").
  if (rawTokens.length === 1 && rawTokens[0].length < 3) return false;
  const evTokens = tokens(evName);
  return rawTokens.every((t) => evTokens.includes(t));
}

/**
 * Providers shorten some teams to the ESPN abbreviation (`NEV @ UCLA`), and
 * the alias table only carries the majors. Treat a short single-token name as
 * an abbreviation candidate so it can be compared to the event's own
 * abbreviation.
 */
function abbreviationOf(value) {
  const n = normalizeTeamName(value);
  return /^[a-z0-9]{2,5}$/.test(n) ? n : '';
}

const ABBREV_SCORE = 0.8;

/**
 * Score how well one stream side matches one event side. Returns 0 when the
 * sides do not match. Abbreviation and partial-token matches score below a
 * full canonical-name match so an exact alias still wins a tie.
 */
function sideScore(rawCanon, rawAbbrev, rawTokens, evName, evCanon, evAbbrev) {
  if (rawCanon && rawCanon === evCanon) return similarity(rawCanon, evCanon);
  if (rawAbbrev && rawAbbrev === evAbbrev) return ABBREV_SCORE;
  if (partialSide(rawTokens, evName)) return PARTIAL_SCORE;
  return 0;
}

/**
 * Lower is better. Series/rematches produce several events with the same
 * teams: prefer one likely in progress, then the soonest upcoming, then the
 * most recently started. Time-based because cached ESPN status can be stale.
 */
const LIKELY_LIVE_MS = 5 * 60 * 60_000;
function timeRank(ev, now) {
  const start = Date.parse(ev.startTime);
  if (Number.isNaN(start)) return Number.MAX_SAFE_INTEGER;
  const delta = start - now.getTime();
  if (delta <= 0 && -delta < LIKELY_LIVE_MS && ev.status?.state !== 'post') return -delta;
  if (delta > 0) return 1e13 + delta;
  return 2e13 - delta;
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
export function matchStream(tvgId, events, { now = new Date() } = {}) {
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
  const awayAbbrev = abbreviationOf(awayRaw);
  const homeAbbrev = abbreviationOf(homeRaw);
  const awayTokens = tokens(awayRaw);
  const homeTokens = tokens(homeRaw);

  let best = null;
  for (const ev of events) {
    const evAwayName = ev.away?.name || '';
    const evHomeName = ev.home?.name || '';
    const evAway = resolveCanonical(evAwayName);
    const evHome = resolveCanonical(evHomeName);
    const evAwayAbbrev = abbreviationOf(ev.away?.abbreviation);
    const evHomeAbbrev = abbreviationOf(ev.home?.abbreviation);

    // A match requires the *pair* to align. Allow swap so a home/away
    // mismatch doesn't kill the match (some providers label differently).
    const normalAway = sideScore(awayCanon, awayAbbrev, awayTokens, evAwayName, evAway, evAwayAbbrev);
    const normalHome = sideScore(homeCanon, homeAbbrev, homeTokens, evHomeName, evHome, evHomeAbbrev);
    const swappedAway = sideScore(awayCanon, awayAbbrev, awayTokens, evHomeName, evHome, evHomeAbbrev);
    const swappedHome = sideScore(homeCanon, homeAbbrev, homeTokens, evAwayName, evAway, evAwayAbbrev);
    const sameSide = normalAway > 0 && normalHome > 0;
    const swapped = swappedAway > 0 && swappedHome > 0;
    if (!sameSide && !swapped) continue;
    // Prefer the normal orientation when both align, and score against the
    // orientation that actually matched so a swapped pair still clears the
    // caller's threshold.
    const score = sameSide
      ? (normalAway + normalHome) / 2
      : (swappedAway + swappedHome) / 2;
    const rank = timeRank(ev, now);
    if (!best || score > best.confidence || (score === best.confidence && rank < best.rank)) {
      best = { event: ev, confidence: score, rank, swapped: !sameSide, reason: { awayCanon, homeCanon } };
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
