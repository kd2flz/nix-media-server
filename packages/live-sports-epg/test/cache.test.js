'use strict';

import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { FileCache } from '../src/cache/file-cache.js';

let dir;
let cache;
before(async () => { dir = await fs.mkdtemp(path.join(os.tmpdir(), 'lse-')); cache = new FileCache({ dir }); });
after(async () => { await fs.rm(dir, { recursive: true, force: true }); });

describe('FileCache', () => {
  it('returns null for missing keys', async () => {
    assert.equal(await cache.get('ns', 'missing'), null);
  });

  it('round-trips a value with no TTL', async () => {
    await cache.set('ns', 'k', { hello: 'world' });
    assert.deepEqual(await cache.get('ns', 'k'), { hello: 'world' });
  });

  it('honors TTL and returns null after expiry', async () => {
    await cache.set('ns', 'k2', { v: 1 }, { ttlMs: 50 });
    assert.deepEqual(await cache.get('ns', 'k2'), { v: 1 });
    await new Promise((r) => setTimeout(r, 80));
    assert.equal(await cache.get('ns', 'k2'), null);
  });

  it('list and delete work', async () => {
    await cache.set('a', '1', 1);
    await cache.set('a', '2', 2);
    const keys = await cache.list('a');
    assert.deepEqual(new Set(keys), new Set(['1', '2']));
    await cache.delete('a', '1');
    assert.deepEqual(new Set(await cache.list('a')), new Set(['2']));
  });
});
