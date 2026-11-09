'use strict';

import { describe, it, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';

import { loadConfig } from '../src/config/loader.js';

const MANAGED_ENV = ['M3U_URL', 'ESPN_BASE_URL', 'CONFIG_FILE', 'OUTPUT_PATH'];

let saved;

beforeEach(() => {
  saved = Object.fromEntries(MANAGED_ENV.map((k) => [k, process.env[k]]));
  for (const k of MANAGED_ENV) delete process.env[k];
});

afterEach(() => {
  for (const k of MANAGED_ENV) {
    if (saved[k] === undefined) delete process.env[k];
    else process.env[k] = saved[k];
  }
});

describe('config loader', () => {
  it('accepts ESPN_BASE_URL for offline/end-to-end runs', () => {
    process.env.M3U_URL = 'http://127.0.0.1:9192/m3u';
    process.env.ESPN_BASE_URL = 'http://127.0.0.1:9192/espn';
    const cfg = loadConfig();
    assert.equal(cfg.espnBaseUrl, 'http://127.0.0.1:9192/espn');
  });

  it('leaves espnBaseUrl undefined so production uses the public ESPN API', () => {
    process.env.M3U_URL = 'http://127.0.0.1:9192/m3u';
    const cfg = loadConfig();
    assert.equal(cfg.espnBaseUrl, undefined);
  });
});
