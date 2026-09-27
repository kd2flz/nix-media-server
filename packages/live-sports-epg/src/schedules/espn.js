'use strict';

import { SPORTS } from '../types/sports.js';

const ESPN_BASE = 'https://site.api.espn.com/apis/site/v2/sports';
const DEFAULT_TIMEOUT_MS = 10_000;

/**
 * Build the ESPN scoreboard URL for a given sport. `date` is a single YYYYMMDD
 * day (ESPN rejects ranges with HTTP 400); if omitted, ESPN returns only its
 * "current" slate (today for MLB/NHL, this week for NFL).
 */
function urlFor(espnSlug, date, query) {
  const params = ['limit=500'];
  if (query) params.push(query);
  if (date) params.push(`dates=${date}`);
  return `${ESPN_BASE}/${espnSlug}/scoreboard?${params.join('&')}`;
}

/**
 * Fetch with timeout + retry. Returns parsed JSON or throws.
 */
async function fetchJson(url, { timeoutMs = DEFAULT_TIMEOUT_MS, retries = 1, fetchImpl = fetch } = {}) {
  let lastErr;
  for (let attempt = 0; attempt <= retries; attempt++) {
    const controller = new AbortController();
    const t = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const res = await fetchImpl(url, { signal: controller.signal, headers: { 'User-Agent': 'live-sports-epg/0.1' } });
      clearTimeout(t);
      if (!res.ok) {
        throw new Error(`ESPN ${url} returned HTTP ${res.status}`);
      }
      return await res.json();
    } catch (err) {
      clearTimeout(t);
      lastErr = err;
      // brief backoff before retry
      if (attempt < retries) await new Promise((r) => setTimeout(r, 500));
    }
  }
  throw lastErr;
}

/**
 * Shape a raw ESPN event into our internal Event type. ESPN's payload is large
 * and only partially stable; we only pull what we need.
 *
 *   { id, sport, league, startTime, endTime,
 *     away: { id, name, abbreviation, score, logo },
 *     home: { id, name, abbreviation, score, logo },
 *     status: { state, detail, period, clock },
 *     venue: { name, city, state },
 *     broadcasts: [...] }
 *
 * `logo` is ESPN's team badge image URL (e.g.
 * "https://a.espncdn.com/i/teamlogos/mlb/500/scoreboard/atl.png") — stable,
 * no auth required. Used to pick a per-channel <icon> in the XMLTV output
 * (see xmltv/generator.js: home feed → home team logo, away feed → away
 * team logo).
 */
function shapeEvent(raw, sport) {
  const comp = raw.competitions?.[0] || {};
  const competitors = comp.competitors || [];
  if (competitors.length < 2) return null;

  // ESPN tags one competitor as home and the other away, but the field is
  // sometimes missing. Default to first=away, second=home.
  const away = competitors.find((c) => c.homeAway === 'away') || competitors[0];
  const home = competitors.find((c) => c.homeAway === 'home') || competitors[1];

  const startTime = comp.date || raw.date;
  // ESPN doesn't always return an end time. Fall back to a sensible default
  // per sport — used as the <programme stop=...> end so IPTV clients know
  // when the program is over. The fallback is conservative.
  const endTime = null; // leave null; CLI / XMLTV layer applies the fallback

  return {
    id: raw.id || comp.id,
    sport,
    league: raw.league?.name || sport.label,
    startTime,
    endTime,
    status: {
      state: comp.status?.type?.state || 'pre',
      detail: comp.status?.type?.description || '',
      period: comp.status?.period || 0,
      clock: comp.status?.displayClock || '',
    },
    away: {
      id: away.team?.id,
      name: away.team?.displayName || away.team?.name || '',
      abbreviation: away.team?.abbreviation || '',
      score: away.score,
      logo: away.team?.logo || '',
    },
    home: {
      id: home.team?.id,
      name: home.team?.displayName || home.team?.name || '',
      abbreviation: home.team?.abbreviation || '',
      score: home.score,
      logo: home.team?.logo || '',
    },
    venue: comp.venue
      ? {
          name: comp.venue.fullName || '',
          city: comp.venue.address?.city || '',
          state: comp.venue.address?.state || '',
        }
      : null,
    broadcasts: (comp.broadcasts || [])
      .flatMap((b) => b.names || [])
      .filter(Boolean),
  };
}

/**
 * Pull scoreboard events for all configured sports. Returns:
 *   { events: [...], failures: [{sport, error}], fetchedAt }
 *
 * Failures are non-fatal: a single sport API outage shouldn't blank the EPG.
 */
export async function fetchAllEvents({
  sports = Object.keys(SPORTS),
  dates = [],                  // e.g. ['20260830', '20260831'] for lookahead window
  fetchImpl,
  timeoutMs,
  retries,
  onProgress,
} = {}) {
  const events = [];
  const failures = [];

  // One request per sport per day: ESPN's default scoreboard only covers the
  // current slate, and date ranges are rejected. A failed day is non-fatal.
  for (const key of sports) {
    const sport = SPORTS[key];
    if (!sport) {
      failures.push({ sport: key, error: 'unknown sport' });
      continue;
    }
    const seen = new Set();
    for (const date of dates.length > 0 ? dates : [undefined]) {
      try {
        const url = urlFor(sport.espnSlug, date, sport.query);
        const data = await fetchJson(url, { fetchImpl, timeoutMs, retries });
        const raw = Array.isArray(data?.events) ? data.events : [];
        for (const r of raw) {
          const ev = shapeEvent(r, sport);
          if (!ev || seen.has(ev.id)) continue;
          seen.add(ev.id);
          events.push(ev);
        }
      } catch (err) {
        failures.push({ sport: key, date, error: err.message });
      }
    }
    if (onProgress) onProgress({ sport: key, count: events.length });
  }

  return {
    events,
    failures,
    fetchedAt: new Date().toISOString(),
  };
}

/**
 * Apply a per-sport default duration when the schedule source didn't
 * provide an end time. The default is the *median* game length, not the
 * blowout-or-tied-up innings-forever maximum.
 */
export const DEFAULT_DURATIONS_MINUTES = {
  MLB: 195,    // ~3h15m (most regular-season games)
  NFL: 210,    // 3h30m incl. commercial time
  NBA: 150,    // 2h30m
  NHL: 150,    // 2h30m
  EPL: 120,    // 2h incl. stoppage
  UCL: 150,
  LA_LIGA: 120,
  BUNDESLIGA: 120,
  SERIE_A: 120,
  LIGUE_1: 120,
  MLS: 130,
  WC: 130,
  NCAAF: 210,
  NCAAB: 150,
};

export { shapeEvent, urlFor };
