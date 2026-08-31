'use strict';

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { parseM3U, parseExtinf, filterLiveGameEntries } from '../src/m3u/parser.js';

describe('parseExtinf', () => {
  it('extracts tvg-id, logo, group-title and name', () => {
    const line = '#EXTINF:0 tvg-id="Reds @ Cubs-A" tvg-logo="https://x/y.png" group-title="Live-Games",Reds @ Cubs-A';
    assert.deepEqual(parseExtinf(line), {
      tvgId: 'Reds @ Cubs-A',
      tvgLogo: 'https://x/y.png',
      groupTitle: 'Live-Games',
      name: 'Reds @ Cubs-A',
    });
  });

  it('handles missing optional attributes', () => {
    const r = parseExtinf('#EXTINF:0 tvg-id="ESPN",ESPN');
    assert.equal(r.tvgId, 'ESPN');
    assert.equal(r.name, 'ESPN');
    assert.equal(r.tvgLogo, undefined);
    assert.equal(r.groupTitle, undefined);
  });

  it('returns null for non-EXTINF lines', () => {
    assert.equal(parseExtinf('#EXTM3U'), null);
    assert.equal(parseExtinf('https://stream/a.m3u8'), null);
    assert.equal(parseExtinf(''), null);
  });

  it('handles missing comma gracefully', () => {
    assert.equal(parseExtinf('#EXTINF:0 broken-no-comma'), null);
  });
});

describe('parseM3U', () => {
  it('parses a simple playlist with one entry', () => {
    const m3u = [
      '#EXTM3U',
      '#EXTINF:0 tvg-id="ESPN" group-title="Live-Channels",ESPN',
      'http://example/espn.m3u8',
      '',
    ].join('\n');
    const r = parseM3U(m3u);
    assert.equal(r.length, 1);
    assert.equal(r[0].tvgId, 'ESPN');
    assert.equal(r[0].url, 'http://example/espn.m3u8');
  });

  it('parses multiple entries and preserves order', () => {
    const m3u = [
      '#EXTM3U',
      '#EXTINF:0 tvg-id="A",A',
      'http://a',
      '#EXTINF:0 tvg-id="B",B',
      'http://b',
      '#EXTINF:0 tvg-id="C",C',
      'http://c',
    ].join('\n');
    const ids = parseM3U(m3u).map((e) => e.tvgId);
    assert.deepEqual(ids, ['A', 'B', 'C']);
  });

  it('skips malformed lines without throwing', () => {
    const m3u = [
      '#EXTM3U',
      '#EXTINF:0 tvg-id="Good",Good',
      'http://good',
      'this is not a url with no preceding EXTINF',
      '#EXTINF:0 tvg-id="Bad-No-Comma"',
      '#EXTINF:0 tvg-id="Also-Good",Also-Good',
      'http://also-good',
    ].join('\n');
    const r = parseM3U(m3u);
    assert.equal(r.length, 2);
    assert.equal(r[0].tvgId, 'Good');
    assert.equal(r[1].tvgId, 'Also-Good');
  });

  it('returns empty array for empty input', () => {
    assert.deepEqual(parseM3U(''), []);
    assert.deepEqual(parseM3U(null), []);
  });
});

describe('filterLiveGameEntries', () => {
  it('keeps entries with Live-Games group-title', () => {
    const entries = [
      { tvgId: 'X', groupTitle: 'Live-Channels' },
      { tvgId: 'Y', groupTitle: 'Live-Games' },
    ];
    const r = filterLiveGameEntries(entries);
    assert.equal(r.length, 1);
    assert.equal(r[0].tvgId, 'Y');
  });

  it('falls back to pattern matching when group-title is missing', () => {
    const entries = [
      { tvgId: 'Reds @ Cubs-A' },  // no group-title but matches pattern
      { tvgId: 'ESPN' },
    ];
    const r = filterLiveGameEntries(entries);
    assert.equal(r.length, 1);
    assert.equal(r[0].tvgId, 'Reds @ Cubs-A');
  });

  it('keeps -A and -H variants', () => {
    const entries = [
      { tvgId: 'Reds @ Cubs-A', groupTitle: 'Live-Games' },
      { tvgId: 'Reds @ Cubs-H', groupTitle: 'Live-Games' },
    ];
    const r = filterLiveGameEntries(entries);
    assert.equal(r.length, 2);
  });
});
