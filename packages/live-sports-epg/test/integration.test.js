'use strict';

/**
 * Integration test: feed a real-looking M3U through the parser, match
 * against a stubbed schedule, and assert the resulting XMLTV.
 */
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';

import { parseM3U, filterLiveGameEntries } from '../src/m3u/parser.js';
import { matchStream } from '../src/matching/matcher.js';
import { renderXmltv } from '../src/xmltv/generator.js';

const M3U = [
  '#EXTM3U',
  '#EXTINF:0 tvg-id="Reds @ Cubs-A" tvg-logo="https://logo/cubs.png" group-title="Live-Games",Reds @ Cubs-A',
  'https://stream/reds-cubs-a.m3u8',
  '#EXTINF:0 tvg-id="Reds @ Cubs-H" tvg-logo="https://logo/cubs.png" group-title="Live-Games",Reds @ Cubs-H',
  'https://stream/reds-cubs-h.m3u8',
  '#EXTINF:0 tvg-id="Red Sox @ Yankees-A" group-title="Live-Games",Red Sox @ Yankees-A',
  'https://stream/sox-yankees-a.m3u8',
  '#EXTINF:0 tvg-id="ESPN" group-title="Live-Channels",ESPN',
  'https://stream/espn.m3u8',
  '#EXTINF:0 tvg-id="Lions @ Colts" group-title="Live-Games",Lions @ Colts',
  'https://stream/lions-colts.m3u8',
].join('\n');

const SCHEDULE = [
  {
    id: 'mlb-1',
    sport: { key: 'MLB', label: 'MLB' },
    league: 'MLB',
    startTime: '2026-08-30T22:50:00Z',
    endTime: null,
    away: { name: 'Cincinnati Reds', abbreviation: 'CIN' },
    home: { name: 'Chicago Cubs', abbreviation: 'CHC' },
    status: { state: 'pre', detail: 'Scheduled' },
    venue: { name: 'Wrigley Field', city: 'Chicago', state: 'IL' },
    broadcasts: ['ESPN'],
  },
  {
    id: 'mlb-2',
    sport: { key: 'MLB', label: 'MLB' },
    league: 'MLB',
    startTime: '2026-08-30T22:50:00Z',
    endTime: null,
    away: { name: 'Boston Red Sox', abbreviation: 'BOS' },
    home: { name: 'New York Yankees', abbreviation: 'NYY' },
    status: { state: 'pre', detail: '' },
    venue: null, broadcasts: [],
  },
  {
    id: 'nfl-1',
    sport: { key: 'NFL', label: 'NFL' },
    league: 'NFL',
    startTime: '2026-08-29T00:20:00Z',
    endTime: null,
    away: { name: 'Detroit Lions', abbreviation: 'DET' },
    home: { name: 'Indianapolis Colts', abbreviation: 'IND' },
    status: { state: 'pre', detail: '' },
    venue: null, broadcasts: [],
  },
];

describe('integration', () => {
  it('parses → filters → matches → renders a valid XMLTV document', () => {
    const all = parseM3U(M3U);
    assert.equal(all.length, 5);

    const live = filterLiveGameEntries(all);
    assert.equal(live.length, 4); // 4 Live-Games, ESPN is Live-Channels

    const matches = new Map();
    for (const entry of live) {
      const m = matchStream(entry.tvgId, SCHEDULE);
      if (m.matched) matches.set(entry.tvgId, { entry, match: m, sport: m.event.sport?.key });
    }

    assert.equal(matches.size, 4, 'all 4 live streams should match');

     const xml = renderXmltv(live, matches, {
       sportByName: {
         'Reds @ Cubs-A': 'MLB',
         'Reds @ Cubs-H': 'MLB',
         'Red Sox @ Yankees-A': 'MLB',
         'Lions @ Colts': 'NFL',
       },
       defaultDurations: { MLB: 195, NFL: 210 },
     });

    // All four live channels present
    for (const tvgId of ['Reds @ Cubs-A', 'Reds @ Cubs-H', 'Red Sox @ Yankees-A', 'Lions @ Colts']) {
      assert.match(xml, new RegExp(`<channel id="${tvgId.replace(/[.@]/g, '\\$&')}">`), `missing <channel> for ${tvgId}`);
      assert.match(xml, new RegExp(`<programme [^>]*channel="${tvgId.replace(/[.@]/g, '\\$&')}"`), `missing <programme> for ${tvgId}`);
    }

    // Matched programmes should include team names
    assert.match(xml, /Cincinnati Reds at Chicago Cubs/);
    assert.match(xml, /Boston Red Sox at New York Yankees/);
    assert.match(xml, /Detroit Lions at Indianapolis Colts/);

    // End times are derived from defaults: MLB=195min, NFL=210min
    // Reds @ Cubs start 22:50, end 22:50+195 = 02:05 next day
    assert.match(xml, /20260831020500 \+0000/);
  });

  it('survives a malformed M3U line without dropping the whole batch', () => {
    const bad = [
      '#EXTM3U',
      '#EXTINF:0 tvg-id="Reds @ Cubs-A" group-title="Live-Games",Reds @ Cubs-A',
      'https://stream/ok.m3u8',
      '#EXTINF:0 tvg-id="Good",Good', // missing comma → null
      'https://stream/should-be-skipped.m3u8',
      '#EXTINF:0 tvg-id="Red Sox @ Yankees-A" group-title="Live-Games",Red Sox @ Yankees-A',
      'https://stream/ok2.m3u8',
    ].join('\n');
    const live = filterLiveGameEntries(parseM3U(bad));
    assert.equal(live.length, 2);
    const xml = renderXmltv(live, new Map());
    assert.match(xml, /<channel id="Reds @ Cubs-A">/);
    assert.match(xml, /<channel id="Red Sox @ Yankees-A">/);
  });
});
