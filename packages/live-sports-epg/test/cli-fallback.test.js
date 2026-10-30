'use strict';

/**
 * Startup fallback tests for the CLI.
 *
 * These spawn the real entrypoint so we cover the ordering that matters:
 * seed `lastEpgText` from the previous output *before* the initial refresh.
 * A dead M3U URL is used so the refresh fails without reaching ESPN.
 */
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { promises as fs } from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const PKG_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

const CACHED = `<?xml version="1.0" encoding="UTF-8"?>
<tv>
  <channel id="Reds @ Cubs-A"><display-name>Reds @ Cubs-A</display-name></channel>
  <programme start="20260830225000 +0000" stop="20260831020500 +0000" channel="Reds @ Cubs-A"><title>Cincinnati Reds at Chicago Cubs</title></programme>
</tv>
`;

async function tempDir() {
  return await fs.mkdtemp(path.join(os.tmpdir(), 'live-sports-epg-fallback-'));
}

async function freePort() {
  const server = net.createServer();
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  await new Promise((resolve) => server.close(resolve));
  return port;
}

function startCli(env) {
  const child = spawn(process.execPath, ['src/cli.js'], {
    cwd: PKG_DIR,
    env: { ...process.env, ...env },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const out = { stdout: '', stderr: '' };
  child.stdout.on('data', (chunk) => { out.stdout += chunk; });
  child.stderr.on('data', (chunk) => { out.stderr += chunk; });
  return { child, out };
}

function waitForExit(child, timeoutMs = 10_000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('process did not exit')), timeoutMs);
    child.once('exit', (code, signal) => {
      clearTimeout(timer);
      resolve({ code, signal });
    });
  });
}

async function waitForEpg(port, timeoutMs = 10_000) {
  const deadline = Date.now() + timeoutMs;
  let lastErr;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`http://127.0.0.1:${port}/epg.xml`);
      if (res.ok) return await res.text();
      lastErr = new Error(`HTTP ${res.status}`);
    } catch (err) {
      lastErr = err;
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw lastErr || new Error('timed out waiting for EPG');
}

async function baseEnv(tmp, overrides = {}) {
  return {
    M3U_URL: `http://127.0.0.1:${await freePort()}/dead.m3u`,
    OUTPUT_PATH: path.join(tmp, 'out', 'epg.xml'),
    CACHE_DIR: path.join(tmp, 'cache'),
    LISTEN_PORT: String(await freePort()),
    REFRESH_MINUTES: '5',
    SPORTS: 'MLB',
    FETCH_TIMEOUT_MS: '1000',
    FETCH_RETRIES: '0',
    LOG_LEVEL: 'info',
    ...overrides,
  };
}

describe('cli startup fallback', () => {
  it('serves the previous output when the M3U source is unreachable', { timeout: 20_000 }, async () => {
    const tmp = await tempDir();
    const env = await baseEnv(tmp);
    await fs.mkdir(path.dirname(env.OUTPUT_PATH), { recursive: true });
    await fs.writeFile(env.OUTPUT_PATH, CACHED);

    const { child, out } = startCli(env);
    try {
      const body = await waitForEpg(Number(env.LISTEN_PORT));
      assert.equal(body, CACHED);
      assert.match(out.stdout, /Seeded EPG fallback from existing output/);
      assert.match(out.stdout, /Serving last successful EPG/);
      assert.equal(child.exitCode, null, 'process should stay alive serving the cache');
    } finally {
      child.kill('SIGTERM');
      await waitForExit(child);
    }

    assert.equal(await fs.readFile(env.OUTPUT_PATH, 'utf8'), CACHED);
    assert.equal((await fs.stat(env.OUTPUT_PATH)).isFile(), true);
  });

  it('exits non-zero when there is no cache to fall back on', { timeout: 20_000 }, async () => {
    const tmp = await tempDir();
    const env = await baseEnv(tmp);

    const { child, out } = startCli(env);
    const { code } = await waitForExit(child);
    assert.notEqual(code, 0);
    assert.match(out.stderr, /Initial refresh failed and no cached EPG/);
  });

  it('ignores an empty cached output', { timeout: 20_000 }, async () => {
    const tmp = await tempDir();
    const env = await baseEnv(tmp);
    await fs.mkdir(path.dirname(env.OUTPUT_PATH), { recursive: true });
    await fs.writeFile(env.OUTPUT_PATH, '   \n');

    const { child, out } = startCli(env);
    const { code } = await waitForExit(child);
    assert.notEqual(code, 0);
    assert.doesNotMatch(out.stdout, /Seeded EPG fallback/);
  });
});
