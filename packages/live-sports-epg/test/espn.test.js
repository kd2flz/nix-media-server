'use strict';

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { fetchAllEvents, urlFor } from '../src/schedules/espn.js';

const rawEvent = (id) => ({
  id,
  date: '2026-09-26T16:00Z',
  competitions: [{
    competitors: [
      { homeAway: 'away', team: { displayName: 'Away' } },
      { homeAway: 'home', team: { displayName: 'Home' } },
    ],
  }],
});

describe('ESPN schedule fetch', () => {
  it('builds single-day URLs with the sport query', () => {
    assert.equal(
      urlFor('football/college-football', '20260926', 'groups=80'),
      'https://site.api.espn.com/apis/site/v2/sports/football/college-football/scoreboard?limit=500&groups=80&dates=20260926',
    );
  });

  it('fetches once per date, dedupes, and keeps going when a day fails', async () => {
    const urls = [];
    const fetchImpl = async (url) => {
      urls.push(url);
      if (url.includes('dates=20260928')) return { ok: false, status: 500 };
      const events = url.includes('dates=20260926') ? [rawEvent('1'), rawEvent('2')] : [rawEvent('2'), rawEvent('3')];
      return { ok: true, json: async () => ({ events }) };
    };
    const { events, failures } = await fetchAllEvents({
      sports: ['NCAAF'],
      dates: ['20260926', '20260927', '20260928'],
      fetchImpl,
      retries: 0,
    });
    assert.equal(urls.length, 3);
    assert.ok(urls.every((u) => u.includes('groups=80')));
    assert.deepEqual(events.map((e) => e.id), ['1', '2', '3']);
    assert.equal(failures.length, 1);
    assert.equal(failures[0].date, '20260928');
  });
});
