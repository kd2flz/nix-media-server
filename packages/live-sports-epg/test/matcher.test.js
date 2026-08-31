'use strict';

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  normalizeTeamName, splitVariant, splitTeams, stripNoise,
} from '../src/matching/normalize.js';
import { resolveCanonical, matchStream } from '../src/matching/matcher.js';

describe('normalizeTeamName', () => {
  it('lowercases and strips diacritics', () => {
    assert.equal(normalizeTeamName('Atlético Madrid'), 'atletico madrid');
  });
  it('collapses whitespace', () => {
    assert.equal(normalizeTeamName('  Red   Sox  '), 'red sox');
  });
  it('expands ampersand', () => {
    assert.equal(normalizeTeamName('Cleveland Bar & Grill'), 'cleveland bar and grill');
  });
  it('handles empty/null', () => {
    assert.equal(normalizeTeamName(''), '');
    assert.equal(normalizeTeamName(null), '');
  });
});

describe('splitVariant', () => {
  it('parses -A suffix', () => {
    const r = splitVariant('Reds @ Cubs-A');
    assert.equal(r.variant, 'A');
    assert.equal(r.event, 'Reds @ Cubs');
  });
  it('parses -H suffix', () => {
    const r = splitVariant('Reds @ Cubs-H');
    assert.equal(r.variant, 'H');
    assert.equal(r.event, 'Reds @ Cubs');
  });
  it('parses space-separated variants', () => {
    assert.equal(splitVariant('Reds @ Cubs - H').variant, 'H');
    assert.equal(splitVariant('Reds @ Cubs H').variant, 'H');
  });
  it('returns null variant when no suffix', () => {
    assert.equal(splitVariant('Reds @ Cubs').variant, null);
    assert.equal(splitVariant('Reds @ Cubs').event, 'Reds @ Cubs');
  });
  it('case-insensitive', () => {
    assert.equal(splitVariant('Reds @ Cubs-a').variant, 'A');
  });
});

describe('splitTeams', () => {
  it('@ separator', () => {
    assert.deepEqual(splitTeams('Reds @ Cubs'), ['Reds', 'Cubs']);
  });
  it('vs separator', () => {
    assert.deepEqual(splitTeams('Reds vs. Cubs'), ['Reds', 'Cubs']);
  });
  it('at separator', () => {
    assert.deepEqual(splitTeams('Reds at Cubs'), ['Reds', 'Cubs']);
  });
  it('slash separator', () => {
    assert.deepEqual(splitTeams('Reds/Cubs'), ['Reds', 'Cubs']);
  });
  it('returns single team if no separator', () => {
    assert.deepEqual(splitTeams('LoneWolf'), ['LoneWolf', null]);
  });
});

describe('stripNoise', () => {
  it('removes sport-specific suffixes', () => {
    assert.equal(stripNoise('Boston Red Sox MLB'), 'Boston Red Sox');
    assert.equal(stripNoise('Dallas Cowboys NFL'), 'Dallas Cowboys');
  });
  it('removes country noise', () => {
    assert.equal(stripNoise('USA Baseball Team'), 'Baseball Team');
  });
});

describe('resolveCanonical', () => {
  it('resolves common aliases', () => {
    assert.equal(resolveCanonical('Yankees'), 'new york yankees');
    assert.equal(resolveCanonical('red sox'), 'boston red sox');
    assert.equal(resolveCanonical('Man Utd'), 'manchester united');
  });
  it('returns normalized form for unknown teams', () => {
    assert.equal(resolveCanonical('St. Louis Bluebongs'), 'st louis bluebongs');
  });
});

describe('matchStream', () => {
  const sampleEvents = [
    {
      id: '1',
      sport: { key: 'MLB', label: 'MLB' },
      league: 'MLB',
      startTime: '2026-08-30T22:50:00Z',
      endTime: null,
      away: { name: 'Cincinnati Reds', abbreviation: 'CIN' },
      home: { name: 'Chicago Cubs', abbreviation: 'CHC' },
      status: { state: 'pre', detail: '7:20 PM EDT' },
    },
    {
      id: '2',
      sport: { key: 'NFL', label: 'NFL' },
      league: 'NFL',
      startTime: '2026-09-07T17:00:00Z',
      endTime: null,
      away: { name: 'New York Yankees', abbreviation: 'NYY' }, // wrong sport
      home: { name: 'Boston Red Sox', abbreviation: 'BOS' },
    },
  ];

  it('matches "Reds @ Cubs-A" to the right event', () => {
    const r = matchStream('Reds @ Cubs-A', sampleEvents);
    assert.equal(r.matched, true);
    assert.equal(r.event.id, '1');
    assert.equal(r.variant, 'A');
  });

  it('matches "Reds @ Cubs-H" with H variant', () => {
    const r = matchStream('Reds @ Cubs-H', sampleEvents);
    assert.equal(r.matched, true);
    assert.equal(r.variant, 'H');
  });

  it('handles team abbreviations', () => {
    // "CIN @ CHC" should still match the Reds/Cubs event
    const r = matchStream('CIN @ CHC-A', sampleEvents);
    assert.equal(r.matched, true);
    assert.equal(r.event.id, '1');
  });

  it('returns matched:false for empty input', () => {
    const r = matchStream('Reds @ Cubs-A', []);
    assert.equal(r.matched, false);
  });

  it('returns matched:false when no candidate matches', () => {
    const r = matchStream('Unknown Team A @ Unknown Team B-A', sampleEvents);
    assert.equal(r.matched, false);
  });

  it('does not throw on malformed tvgId', () => {
    const r = matchStream('garbage-no-teams', sampleEvents);
    assert.equal(r.matched, false);
  });
});
