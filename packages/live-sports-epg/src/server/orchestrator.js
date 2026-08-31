'use strict';

import { promises as fs } from 'node:fs';
import path from 'node:path';

import { parseM3U, filterLiveGameEntries } from '../m3u/parser.js';
import { matchStream } from '../matching/matcher.js';
import { fetchAllEvents, DEFAULT_DURATIONS_MINUTES } from '../schedules/espn.js';
import { renderXmltv } from '../xmltv/generator.js';
import { FileCache } from '../cache/file-cache.js';
import { log } from '../log/logger.js';

/**
 * Build a list of YYYYMMDD strings for the next `days` days from `now`,
 * in UTC. Used to filter ESPN's scoreboard payload to the look-ahead
 * window we actually care about.
 */
function ymdRange(now, days) {
  const out = [];
  for (let i = 0; i < days; i++) {
    const d = new Date(now.getTime() + i * 24 * 60 * 60_000);
    out.push(d.toISOString().slice(0, 10).replace(/-/g, ''));
  }
  return out;
}

/**
 * The orchestrator. One instance per process. Owns:
 *   - the M3U cache (recent tvg-ids we've seen)
 *   - the schedule cache (per-sport event lists, TTL ~ lookAheadDays)
 *   - the last successful EPG (used as a fallback if a refresh fails)
 *
 * Call `runOnce()` to do a full refresh, or `start()` to schedule periodic
 * refreshes plus an optional HTTP server.
 */
export class EpgService {
  constructor(cfg) {
    this.cfg = cfg;
    this.cache = new FileCache({ dir: cfg.cacheDir });
    this.lastEpgText = null;
    this.lastRunStats = null;
  }

  async _fetchM3U() {
    const res = await fetch(this.cfg.m3uUrl, {
      signal: AbortSignal.timeout(this.cfg.fetchTimeoutMs),
      headers: { 'User-Agent': 'live-sports-epg/0.1' },
    });
    if (!res.ok) throw new Error(`M3U fetch HTTP ${res.status}`);
    return await res.text();
  }

  async _loadSchedule(sports, dates) {
    // Cache each sport's events under a date-keyed namespace. Two hours TTL
    // is a balance between freshness and rate-limiting on ESPN's free tier.
    const TTL_MS = 2 * 60 * 60 * 1000;
    const all = [];
    const failures = [];

    for (const sport of sports) {
      const cacheKey = dates.join(',') + '|' + sport;
      let events = await this.cache.get('schedules', cacheKey);
      if (!events) {
        try {
          const { events: fresh, failures: esf } = await fetchAllEvents({
            sports: [sport],
            fetchTimeoutMs: this.cfg.fetchTimeoutMs,
            retries: this.cfg.fetchRetries,
          });
          events = fresh;
          failures.push(...esf);
          if (events.length) {
            await this.cache.set('schedules', cacheKey, events, { ttlMs: TTL_MS });
          }
        } catch (err) {
          failures.push({ sport, error: err.message });
          events = [];
        }
      }
      all.push(...events);
    }
    return { events: all, failures };
  }

  /**
   * One refresh cycle. Returns the rendered XMLTV text and stats. If the
   * M3U fetch fails, returns the last successful EPG (if any) so the
   * output file never goes blank.
   */
  async runOnce() {
    const t0 = Date.now();
    const stats = {
      startedAt: new Date().toISOString(),
      m3uOk: false,
      m3uEntries: 0,
      liveGameEntries: 0,
      matched: 0,
      unmatched: 0,
      scheduleFailures: [],
      scheduleEvents: 0,
    };

    let m3uText;
    try {
      m3uText = await this._fetchM3U();
      stats.m3uOk = true;
    } catch (err) {
      log.error('M3U fetch failed', { error: err.message });
      if (this.lastEpgText) {
        log.warn('Serving last successful EPG');
        return { xmltv: this.lastEpgText, stats, degraded: true };
      }
      throw err;
    }

    const allEntries = parseM3U(m3uText);
    stats.m3uEntries = allEntries.length;
    const liveEntries = filterLiveGameEntries(allEntries);
    stats.liveGameEntries = liveEntries.length;

    // Drop any previously-seen stream IDs we no longer need to know about
    // (the cache is small; doing it here keeps /var/cache tidy).
    const seen = new Set(liveEntries.map((e) => e.tvgId));
    for (const key of await this.cache.list('streams')) {
      if (!seen.has(key)) await this.cache.delete('streams', key);
    }

    // Load schedule for the look-ahead window.
    const dates = ymdRange(new Date(), this.cfg.lookAheadDays);
    const { events, failures } = await this._loadSchedule(this.cfg.sports, dates);
    stats.scheduleEvents = events.length;
    stats.scheduleFailures = failures;

    // Match each live entry against all events (no sport pre-filter — the
    // matcher resolves canonical names; the extra work is bounded by
    // lookAheadDays * sports * ~10 events/sport/day).
    const matches = new Map();
    const sportByName = {};
    for (const entry of liveEntries) {
      const m = matchStream(entry.tvgId, events);
      if (m.matched && m.confidence >= 0.5) {
        matches.set(entry.tvgId, { entry, match: m, sport: m.event.sport?.key });
        stats.matched++;
        // Best-effort league hint: pick the sport whose events have the
        // most name overlap with this match. ESPN groups by league so this
        // narrows the duration fallback.
        if (m.event.league) sportByName[entry.tvgId] = m.event.league;
      } else {
        stats.unmatched++;
        log.debug('Unmatched stream', {
          tvgId: entry.tvgId,
          confidence: m.confidence,
          reason: m.reason,
        });
      }
    }

    const xmltv = renderXmltv(liveEntries, matches, {
      defaultDurations: DEFAULT_DURATIONS_MINUTES,
      sportByName,
      upcoming: this.cfg.upcoming,
      upcomingMaxHours: this.cfg.upcomingMaxHours,
    });

    this.lastEpgText = xmltv;
    stats.finishedAt = new Date().toISOString();
    stats.elapsedMs = Date.now() - t0;
    this.lastRunStats = stats;

    log.info('EPG refresh', {
      m3uEntries: stats.m3uEntries,
      live: stats.liveGameEntries,
      matched: stats.matched,
      unmatched: stats.unmatched,
      scheduleEvents: stats.scheduleEvents,
      scheduleFailures: failures.length,
      elapsedMs: stats.elapsedMs,
    });
    return { xmltv, stats };
  }

  /** Write the EPG to disk atomically (write to .tmp, rename). */
  async writeOutput(xmltv) {
    const out = this.cfg.outputPath;
    await fs.mkdir(path.dirname(out), { recursive: true });
    const tmp = `${out}.tmp`;
    await fs.writeFile(tmp, xmltv, 'utf8');
    await fs.rename(tmp, out);
  }

  /** Public status for /status endpoint. */
  status() {
    return this.lastRunStats;
  }
}
