'use strict';

import { describe, it, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';

import { loadConfig } from '../src/config/loader.js';

const MANAGED_ENV = [
  'M3U_URL', 'ESPN_BASE_URL', 'CONFIG_FILE', 'OUTPUT_PATH',
  'LISTEN_HOST', 'LISTEN_PORT',
];

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

  it('binds the optional HTTP server to loopback by default', () => {
    process.env.M3U_URL = 'http://127.0.0.1:9192/m3u';
    const cfg = loadConfig();
    assert.equal(cfg.listenHost, '127.0.0.1');
    assert.equal(cfg.listenPort, 0);
  });

  it('accepts an explicit listen host and port', () => {
    process.env.M3U_URL = 'http://127.0.0.1:9192/m3u';
    process.env.LISTEN_HOST = '127.0.0.1';
    process.env.LISTEN_PORT = '8098';
    const cfg = loadConfig();
    assert.equal(cfg.listenHost, '127.0.0.1');
    assert.equal(cfg.listenPort, 8098);
  });

  it('rejects an out-of-range listen port', () => {
    process.env.M3U_URL = 'http://127.0.0.1:9192/m3u';
    process.env.LISTEN_PORT = '70000';
    assert.throws(() => loadConfig(), /listenPort must be between 0 and 65535/);
  });
});
