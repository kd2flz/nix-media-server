'use strict';

import fs from 'node:fs';

/**
 * Load config from a JSON file if it exists, otherwise from environment
 * variables. The file takes precedence so operators can commit a config
 * without surprises from the runtime environment.
 *
 * Required:
 *   m3uUrl: source M3U URL
 *   outputPath: where the generated XMLTV is written
 * Optional:
 *   refreshMinutes: how often to refresh the M3U + schedule (default 5)
 *   lookAheadDays: how many days of events to fetch (default 7)
 *   sports: list of SPORTS keys to enable (default = all)
 *   listenPort: HTTP port to serve the XMLTV on (default 0 = no server)
 *   timezone: only used for the file mtime; timestamps are UTC
 *   logLevel: debug|info|warn|error (default info)
 *   fetchTimeoutMs / fetchRetries: passed through to the schedule provider
 *   upcoming: whether to emit a pre-game "Upcoming:" placeholder programme
 *     for matched events that haven't started yet (default true)
 *   upcomingMaxHours: cap, in hours, on how far before kickoff the
 *     "Upcoming:" block reaches back (default: unset — fills the whole gap)
 */
const ENV = {
  M3U_URL: 'M3U_URL',
  OUTPUT_PATH: 'OUTPUT_PATH',
  REFRESH_MINUTES: 'REFRESH_MINUTES',
  LOOK_AHEAD_DAYS: 'LOOK_AHEAD_DAYS',
  SPORTS: 'SPORTS',
  LISTEN_PORT: 'LISTEN_PORT',
  LOG_LEVEL: 'LOG_LEVEL',
  FETCH_TIMEOUT_MS: 'FETCH_TIMEOUT_MS',
  FETCH_RETRIES: 'FETCH_RETRIES',
  CONFIG_FILE: 'CONFIG_FILE',
  UPCOMING: 'UPCOMING',
  UPCOMING_MAX_HOURS: 'UPCOMING_MAX_HOURS',
};

const ALL_SPORTS = [
  'MLB', 'NFL', 'NBA', 'NHL',
  'EPL', 'UCL', 'LA_LIGA', 'BUNDESLIGA', 'SERIE_A', 'LIGUE_1', 'MLS', 'WC',
  'NCAAF', 'NCAAB',
];

function num(v, dflt) {
  if (v == null || v === '') return dflt;
  const n = Number(v);
  return Number.isFinite(n) ? n : dflt;
}

function bool(v, dflt) {
  if (v == null || v === '') return dflt;
  if (typeof v === 'boolean') return v;
  return String(v).toLowerCase() === 'true' || v === '1';
}

export function loadConfig() {
  const file = process.env[ENV.CONFIG_FILE];
  let fromFile = {};
  if (file) {
    try {
      fromFile = JSON.parse(fs.readFileSync(file, 'utf8'));
    } catch (err) {
      throw new Error(`Failed to read CONFIG_FILE ${file}: ${err.message}`);
    }
  }

  const cfg = {
    m3uUrl: fromFile.m3uUrl || process.env[ENV.M3U_URL],
    outputPath: fromFile.outputPath || process.env[ENV.OUTPUT_PATH] || '/var/lib/live-sports-epg/epg.xml',
    refreshMinutes: num(fromFile.refreshMinutes ?? process.env[ENV.REFRESH_MINUTES], 5),
    lookAheadDays: num(fromFile.lookAheadDays ?? process.env[ENV.LOOK_AHEAD_DAYS], 7),
    sports: fromFile.sports
      || (process.env[ENV.SPORTS] ? process.env[ENV.SPORTS].split(',').map((s) => s.trim()).filter(Boolean) : ALL_SPORTS),
    listenPort: num(fromFile.listenPort ?? process.env[ENV.LISTEN_PORT], 0),
    logLevel: (fromFile.logLevel || process.env[ENV.LOG_LEVEL] || 'info').toLowerCase(),
    fetchTimeoutMs: num(fromFile.fetchTimeoutMs ?? process.env[ENV.FETCH_TIMEOUT_MS], 10_000),
    fetchRetries: num(fromFile.fetchRetries ?? process.env[ENV.FETCH_RETRIES], 1),
    cacheDir: fromFile.cacheDir || process.env.CACHE_DIR || '/var/cache/live-sports-epg',
    upcoming: bool(fromFile.upcoming ?? process.env[ENV.UPCOMING], true),
    upcomingMaxHours: fromFile.upcomingMaxHours != null || process.env[ENV.UPCOMING_MAX_HOURS] != null
      ? num(fromFile.upcomingMaxHours ?? process.env[ENV.UPCOMING_MAX_HOURS], null)
      : null,
  };

  if (!cfg.m3uUrl) {
    throw new Error(`live-sports-epg: m3uUrl is required. Set CONFIG_FILE, or M3U_URL in the environment.`);
  }
  if (cfg.refreshMinutes < 1) {
    throw new Error('refreshMinutes must be >= 1');
  }
  return cfg;
}
