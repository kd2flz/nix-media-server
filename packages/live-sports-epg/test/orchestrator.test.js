'use strict';

/**
 * Fallback behaviour in the refresh loop, without network access.
 */
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { EpgService } from '../src/server/orchestrator.js';

const CACHED = '<tv><channel id="cached"><display-name>Cached</display-name></channel></tv>\n';

async function makeService() {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'live-sports-epg-orch-'));
  const service = new EpgService({
    m3uUrl: 'http://127.0.0.1:9/dead.m3u',
    outputPath: path.join(dir, 'epg.xml'),
    cacheDir: path.join(dir, 'cache'),
    sports: [],
    lookAheadDays: 1,
    fetchTimeoutMs: 10,
    fetchRetries: 0,
    upcoming: false,
    upcomingMaxHours: null,
  });
  service._loadSchedule = async () => ({ events: [], failures: [] });
  service.lastEpgText = CACHED;
  return service;
}

describe('EpgService fallback', () => {
  it('returns the cached guide when the M3U fetch fails', async () => {
    const service = await makeService();
    service._fetchM3U = async () => { throw new Error('connection refused'); };

    const result = await service.runOnce();

    assert.equal(result.degraded, true);
    assert.equal(result.xmltv, CACHED);
    assert.equal(service.lastEpgText, CACHED);
  });

  it('returns the cached guide when the M3U is empty instead of overwriting it', async () => {
    const service = await makeService();
    service._fetchM3U = async () => '';

    const result = await service.runOnce();

    assert.equal(result.degraded, true);
    assert.equal(result.xmltv, CACHED);
    assert.equal(result.stats.m3uEntries, 0);
    assert.equal(service.lastEpgText, CACHED);
  });

  it('treats a header-only M3U as empty', async () => {
    const service = await makeService();
    service._fetchM3U = async () => '#EXTM3U\n';

    const result = await service.runOnce();

    assert.equal(result.degraded, true);
    assert.equal(result.xmltv, CACHED);
  });
});
