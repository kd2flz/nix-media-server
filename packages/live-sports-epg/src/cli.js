#!/usr/bin/env node
'use strict';

import { loadConfig } from './config/loader.js';
import { EpgService } from './server/orchestrator.js';
import { startHttpServer } from './server/http.js';
import { log } from './log/logger.js';

async function main() {
  const cfg = loadConfig();
  process.env.LOG_LEVEL = cfg.logLevel;
  log.info('Starting live-sports-epg', {
    m3uUrl: redactM3uUrl(cfg.m3uUrl),
    refreshMinutes: cfg.refreshMinutes,
    lookAheadDays: cfg.lookAheadDays,
    sports: cfg.sports.join(','),
    outputPath: cfg.outputPath,
    listenPort: cfg.listenPort,
  });

  const service = new EpgService(cfg);

  // Initial refresh; if it fails outright (no fallback to serve), exit
  // non-zero so the systemd unit flags the failure.
  try {
    const { xmltv } = await service.runOnce();
    await service.writeOutput(xmltv);
  } catch (err) {
    log.error('Initial refresh failed and no cached EPG to fall back on', { error: err.message });
    process.exitCode = 1;
    return;
  }

  if (cfg.listenPort) {
    try {
      await startHttpServer(service, { port: cfg.listenPort });
    } catch (err) {
      log.error('Failed to start HTTP server', { error: err.message });
    }
  }

  // Periodic refresh.
  const tick = setInterval(async () => {
    try {
      const { xmltv } = await service.runOnce();
      await service.writeOutput(xmltv);
    } catch (err) {
      log.error('Periodic refresh failed', { error: err.message });
    }
  }, cfg.refreshMinutes * 60_000);
  // Don't keep the event loop alive just for the timer.
  if (typeof tick.unref === 'function') tick.unref();

  // Graceful shutdown on SIGTERM/SIGINT.
  for (const sig of ['SIGTERM', 'SIGINT']) {
    process.on(sig, () => {
      log.info('Received signal, exiting', { signal: sig });
      clearInterval(tick);
      process.exit(0);
    });
  }
}

function redactM3uUrl(u) {
  try {
    const parsed = new URL(u);
    if (parsed.search) parsed.search = '?<redacted>';
    return parsed.toString();
  } catch { return '<unparseable>'; }
}

main().catch((err) => {
  // eslint-disable-next-line no-console
  console.error('Fatal:', err);
  process.exit(1);
});
