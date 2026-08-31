'use strict';

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  xmltvDate, esc, computeEnd, renderChannel, renderProgramme, renderUnmatchedProgramme,
  renderUpcomingProgramme, renderXmltv,
} from '../src/xmltv/generator.js';

describe('xmltvDate', () => {
  it('formats a UTC date in the expected XMLTV format', () => {
    // 2026-08-30T22:50:00Z
    const d = new Date('2026-08-30T22:50:00Z');
    assert.equal(xmltvDate(d), '20260830225000 +0000');
  });
  it('returns empty string for invalid date', () => {
    assert.equal(xmltvDate(new Date('not a date')), '');
    assert.equal(xmltvDate(null), '');
  });
});

describe('esc', () => {
  it('escapes XML special characters', () => {
    assert.equal(esc('a & b < c > d "e" \'f\''), 'a &amp; b &lt; c &gt; d &quot;e&quot; &apos;f&apos;');
  });
  it('passes through safe text', () => {
    assert.equal(esc('hello world'), 'hello world');
  });
  it('handles null and undefined', () => {
    assert.equal(esc(null), '');
    assert.equal(esc(undefined), '');
  });
});

describe('renderChannel', () => {
  it('renders with the exact tvg-id as id', () => {
    const xml = renderChannel('Reds @ Cubs-A', 'Reds @ Cubs-A');
    assert.match(xml, /<channel id="Reds @ Cubs-A">/);
    assert.match(xml, /<display-name lang="en">Reds @ Cubs-A<\/display-name>/);
  });
  it('escapes special characters in display name', () => {
    const xml = renderChannel('X & Y', 'X & Y');
    assert.match(xml, /<display-name lang="en">X &amp; Y<\/display-name>/);
  });
});

describe('renderUnmatchedProgramme', () => {
  it('uses the tvg-id verbatim as channel', () => {
    const xml = renderUnmatchedProgramme('Reds @ Cubs-A', 'Reds @ Cubs-A', {
      startDate: new Date('2026-08-30T22:00:00Z'),
      endDate: new Date('2026-08-30T23:00:00Z'),
    });
    assert.match(xml, /channel="Reds @ Cubs-A"/);
    assert.match(xml, /<live \/>/);
  });
});

describe('renderUpcomingProgramme', () => {
  const match = {
    event: {
      id: '1', sport: { key: 'MLB', label: 'MLB' }, league: 'MLB',
      startTime: '2026-08-30T22:50:00Z', endTime: null,
      away: { name: 'Cincinnati Reds', abbreviation: 'CIN' },
      home: { name: 'Chicago Cubs', abbreviation: 'CHC' },
      status: { state: 'pre', detail: '' },
      venue: null, broadcasts: [],
    },
    variant: 'A', confidence: 1, reason: {},
  };

  it('prefixes the title with "Upcoming:"', () => {
    const xml = renderUpcomingProgramme(
      { tvgId: 'Reds @ Cubs-A' },
      match,
      { startDate: new Date('2026-08-30T20:00:00Z'), endDate: new Date('2026-08-30T22:50:00Z') },
    );
    assert.match(xml, /<title lang="en">Upcoming: Cincinnati Reds at Chicago Cubs<\/title>/);
    assert.match(xml, /<title lang="en-short">Upcoming: CIN @ CHC<\/title>/);
  });

  it('uses the tvg-id verbatim as channel', () => {
    const xml = renderUpcomingProgramme(
      { tvgId: 'Reds @ Cubs-A' },
      match,
      { startDate: new Date('2026-08-30T20:00:00Z'), endDate: new Date('2026-08-30T22:50:00Z') },
    );
    assert.match(xml, /channel="Reds @ Cubs-A"/);
  });

  it('does not emit <live />', () => {
    const xml = renderUpcomingProgramme(
      { tvgId: 'Reds @ Cubs-A' },
      match,
      { startDate: new Date('2026-08-30T20:00:00Z'), endDate: new Date('2026-08-30T22:50:00Z') },
    );
    assert.doesNotMatch(xml, /<live \/>/);
  });
});

describe('renderXmltv', () => {
  it('produces a valid document with DOCTYPE', () => {
    const xml = renderXmltv(
      [{ tvgId: 'X', tvgName: 'X' }],
      new Map(),
    );
    assert.match(xml, /^<\?xml version="1.0" encoding="UTF-8"\?>/);
    assert.match(xml, /<!DOCTYPE tv SYSTEM "xmltv.dtd">/);
    assert.match(xml, /<tv /);
    assert.match(xml, /<\/tv>$/);
  });

  it('emits a <channel> for every M3U entry', () => {
    const entries = [
      { tvgId: 'A', tvgName: 'A' },
      { tvgId: 'B', tvgName: 'B' },
      { tvgId: 'C', tvgName: 'C' },
    ];
    const xml = renderXmltv(entries, new Map());
    const a = (xml.match(/<channel id="A">/g) || []).length;
    const b = (xml.match(/<channel id="B">/g) || []).length;
    const c = (xml.match(/<channel id="C">/g) || []).length;
    assert.equal(a, 1);
    assert.equal(b, 1);
    assert.equal(c, 1);
  });

  it('emits an unmatched programme for entries without a match', () => {
    const entries = [{ tvgId: 'Lone @ Wolf-A', tvgName: 'Lone @ Wolf' }];
    const xml = renderXmltv(entries, new Map());
    assert.match(xml, /<programme [^>]*channel="Lone @ Wolf-A"/);
  });

  it('preserves tvg-id with spaces and @ in the rendered XML', () => {
    const entries = [{ tvgId: 'Reds @ Cubs-A', tvgName: 'Reds @ Cubs' }];
    const match = {
      event: {
        id: '1', sport: { key: 'MLB', label: 'MLB' }, league: 'MLB',
        startTime: '2026-08-30T22:50:00Z', endTime: null,
        away: { name: 'Cincinnati Reds', abbreviation: 'CIN' },
        home: { name: 'Chicago Cubs', abbreviation: 'CHC' },
        status: { state: 'pre', detail: '' },
        venue: null, broadcasts: [],
      },
      variant: 'A', confidence: 1, reason: {},
    };
    const xml = renderXmltv(entries, new Map([['Reds @ Cubs-A', { entry: entries[0], match }]]));
    assert.match(xml, /<programme [^>]*channel="Reds @ Cubs-A"/);
  });

  it('fills the gap before kickoff with an "Upcoming:" programme', () => {
    const entries = [{ tvgId: 'Reds @ Cubs-A', tvgName: 'Reds @ Cubs' }];
    const match = {
      event: {
        id: '1', sport: { key: 'MLB', label: 'MLB' }, league: 'MLB',
        startTime: '2026-08-30T22:50:00Z', endTime: null,
        away: { name: 'Cincinnati Reds', abbreviation: 'CIN' },
        home: { name: 'Chicago Cubs', abbreviation: 'CHC' },
        status: { state: 'pre', detail: '' },
        venue: null, broadcasts: [],
      },
      variant: 'A', confidence: 1, reason: {},
    };
    const now = new Date('2026-08-30T20:00:00Z');
    const xml = renderXmltv(
      entries,
      new Map([['Reds @ Cubs-A', { entry: entries[0], match }]]),
      { now },
    );
    // Upcoming block from now (20:00) to kickoff (22:50)
    assert.match(xml, /<programme start="20260830200000 \+0000" stop="20260830225000 \+0000" channel="Reds @ Cubs-A">\n {2}<title lang="en">Upcoming:/);
    // Followed by the real game programme starting at kickoff
    assert.match(xml, /<programme start="20260830225000 \+0000"[^>]*channel="Reds @ Cubs-A">\n {2}<title lang="en">Cincinnati Reds at Chicago Cubs/);
  });

  it('omits the "Upcoming:" programme once the game has started', () => {
    const entries = [{ tvgId: 'Reds @ Cubs-A', tvgName: 'Reds @ Cubs' }];
    const match = {
      event: {
        id: '1', sport: { key: 'MLB', label: 'MLB' }, league: 'MLB',
        startTime: '2026-08-30T22:50:00Z', endTime: null,
        away: { name: 'Cincinnati Reds', abbreviation: 'CIN' },
        home: { name: 'Chicago Cubs', abbreviation: 'CHC' },
        status: { state: 'in', detail: '' },
        venue: null, broadcasts: [],
      },
      variant: 'A', confidence: 1, reason: {},
    };
    const now = new Date('2026-08-30T23:30:00Z'); // after kickoff
    const xml = renderXmltv(
      entries,
      new Map([['Reds @ Cubs-A', { entry: entries[0], match }]]),
      { now },
    );
    assert.doesNotMatch(xml, /Upcoming:/);
  });

  it('respects upcoming: false to disable the feature', () => {
    const entries = [{ tvgId: 'Reds @ Cubs-A', tvgName: 'Reds @ Cubs' }];
    const match = {
      event: {
        id: '1', sport: { key: 'MLB', label: 'MLB' }, league: 'MLB',
        startTime: '2026-08-30T22:50:00Z', endTime: null,
        away: { name: 'Cincinnati Reds', abbreviation: 'CIN' },
        home: { name: 'Chicago Cubs', abbreviation: 'CHC' },
        status: { state: 'pre', detail: '' },
        venue: null, broadcasts: [],
      },
      variant: 'A', confidence: 1, reason: {},
    };
    const now = new Date('2026-08-30T20:00:00Z');
    const xml = renderXmltv(
      entries,
      new Map([['Reds @ Cubs-A', { entry: entries[0], match }]]),
      { now, upcoming: false },
    );
    assert.doesNotMatch(xml, /Upcoming:/);
  });

  it('respects upcomingMaxHours to cap how far back the block reaches', () => {
    const entries = [{ tvgId: 'Reds @ Cubs-A', tvgName: 'Reds @ Cubs' }];
    const match = {
      event: {
        id: '1', sport: { key: 'MLB', label: 'MLB' }, league: 'MLB',
        startTime: '2026-08-30T22:50:00Z', endTime: null,
        away: { name: 'Cincinnati Reds', abbreviation: 'CIN' },
        home: { name: 'Chicago Cubs', abbreviation: 'CHC' },
        status: { state: 'pre', detail: '' },
        venue: null, broadcasts: [],
      },
      variant: 'A', confidence: 1, reason: {},
    };
    const now = new Date('2026-08-30T18:00:00Z'); // 4h50m before kickoff
    const xml = renderXmltv(
      entries,
      new Map([['Reds @ Cubs-A', { entry: entries[0], match }]]),
      { now, upcomingMaxHours: 2 }, // only fill the last 2 hours
    );
    // Upcoming block should start at 20:50 (2h before 22:50), not at now (18:00)
    assert.match(xml, /<programme start="20260830205000 \+0000" stop="20260830225000 \+0000" channel="Reds @ Cubs-A">\n {2}<title lang="en">Upcoming:/);
    assert.doesNotMatch(xml, /start="20260830180000/);
  });
});

describe('computeEnd', () => {
  it('uses event.endTime when present and valid', () => {
    const start = new Date('2026-08-30T22:50:00Z');
    const ev = { endTime: '2026-08-31T02:00:00Z' };
    assert.equal(computeEnd(start, ev).toISOString(), '2026-08-31T02:00:00.000Z');
  });
  it('falls back to default duration per sport', () => {
    const start = new Date('2026-08-30T22:50:00Z');
    const ev = { sport: { key: 'NFL' } };
    // NFL default = 210 minutes
    const end = computeEnd(start, ev, { NFL: 210 });
    assert.equal(end.getTime() - start.getTime(), 210 * 60_000);
  });
  it('uses 180-minute last-ditch fallback', () => {
    const start = new Date('2026-08-30T22:50:00Z');
    const end = computeEnd(start, {}, {});
    assert.equal(end.getTime() - start.getTime(), 180 * 60_000);
  });
});
