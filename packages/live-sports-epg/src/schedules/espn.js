'use strict';

import { SPORTS } from '../types/sports.js';

const ESPN_BASE = 'https://site.api.espn.com/apis/site/v2/sports';
const DEFAULT_TIMEOUT_MS = 10_000;

/**
 * Build the ESPN scoreboard URL for a given sport. `date` is a YYYYMMDD string
 * in UTC; if omitted, ESPN returns "today + next few days" (default behavior).
 */
function urlFor(espnSlug, date) {
  const base = `${ESPN_BASE}/${espnSlug}/scoreboard`;
  return date ? `${base}?dates=${date}` : base;
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
 *     away: { id, name, abbreviation, score },
 *     home: { id, name, abbreviation, score },
 *     status: { state, detail, period, clock },
 *     venue: { name, city, state },
 *     broadcasts: [...] }
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
    },
    home: {
      id: home.team?.id,
      name: home.team?.displayName || home.team?.name || '',
      abbreviation: home.team?.abbreviation || '',
      score: home.score,
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

  // ESPN's scoreboard endpoint returns ~14 days of games; we call once per
  // sport and filter by date. If `dates` is empty we take whatever ESPN
  // returns and let the caller filter.
  for (const key of sports) {
    const sport = SPORTS[key];
    if (!sport) {
      failures.push({ sport: key, error: 'unknown sport' });
      continue;
    }
    try {
      const url = urlFor(sport.espnSlug);
      const data = await fetchJson(url, { fetchImpl, timeoutMs, retries });
      const raw = Array.isArray(data?.events) ? data.events : [];
      for (const r of raw) {
        const ev = shapeEvent(r, sport);
        if (!ev) continue;
        if (dates.length > 0) {
          const ymd = (ev.startTime || '').slice(0, 10).replace(/-/g, '');
          if (!dates.includes(ymd)) continue;
        }
        events.push(ev);
      }
      if (onProgress) onProgress({ sport: key, count: events.length });
    } catch (err) {
      failures.push({ sport: key, error: err.message });
    }
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
