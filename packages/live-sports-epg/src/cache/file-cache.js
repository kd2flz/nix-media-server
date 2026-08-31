'use strict';

import { promises as fs } from 'node:fs';
import path from 'node:path';

/**
 * A simple JSON file-backed cache. One file per "namespace" so schedule
 * and stream data can be rotated independently. The cache is best-effort:
 * if the file is corrupted or missing, we return an empty cache rather
 * than throwing.
 */
export class FileCache {
  constructor({ dir }) {
    if (!dir) throw new Error('FileCache requires dir');
    this.dir = dir;
  }

  async _path(ns, key) {
    return path.join(this.dir, ns, `${key}.json`);
  }

  async get(ns, key) {
    try {
      const buf = await fs.readFile(await this._path(ns, key), 'utf8');
      const obj = JSON.parse(buf);
      // Treat explicitly-expired entries as misses.
      if (obj?.expiresAt && Date.now() > obj.expiresAt) return null;
      return obj.value;
    } catch {
      return null;
    }
  }

  async set(ns, key, value, { ttlMs = 0 } = {}) {
    const p = await this._path(ns, key);
    await fs.mkdir(path.dirname(p), { recursive: true });
    const obj = { value, savedAt: Date.now(), expiresAt: ttlMs ? Date.now() + ttlMs : 0 };
    await fs.writeFile(p, JSON.stringify(obj, null, 2), 'utf8');
  }

  async delete(ns, key) {
    try { await fs.unlink(await this._path(ns, key)); } catch { /* ignore */ }
  }

  async list(ns) {
    try {
      const entries = await fs.readdir(path.join(this.dir, ns));
      return entries.filter((f) => f.endsWith('.json')).map((f) => f.replace(/\.json$/, ''));
    } catch {
      return [];
    }
  }
}
