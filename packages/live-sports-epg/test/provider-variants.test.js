'use strict';

/**
 * Regression coverage for provider naming quirks.
 *
 * IPTV providers do not follow one naming convention: the same team can show
 * up as "Indianapolis Colts", "Indianapolis-Colts", "IndianapolisColts",
 * "Indianapolis_Colts", or with en/em dashes. Before hyphens/dashes were
 * treated as separators, every hyphenated tvg-id missed the alias table and
 * fell through to the 60-minute "unmatched" placeholder — the NFL games on
 * 2026-11-08 were all invisible in Jellyfin for exactly this reason.
 *
 * These tests deliberately generate the variants from the canonical name so
 * they keep covering new providers as long as the canonical spelling is
 * correct, and they include negative cases so the looser matching cannot
 * quietly pair the wrong teams.
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';

import { ALIASES } from '../src/matching/aliases.js';
import { normalizeTeamName } from '../src/matching/normalize.js';
import { resolveCanonical, matchStream } from '../src/matching/matcher.js';

const VARIANTS = {
  'space separated': (name) => name,
  hyphenated: (name) => name.replace(/\s+/g, '-'),
  'run together': (name) => name.replace(/\s+/g, ''),
  underscore: (name) => name.replace(/\s+/g, '_'),
  dotted: (name) => name.replace(/\s+/g, '.'),
  'en dash': (name) => name.replace(/\s+/g, '\u2013'),
  'em dash': (name) => name.replace(/\s+/g, '\u2014'),
  'non-breaking hyphen': (name) => name.replace(/\s+/g, '\u2011'),
  'unicode minus': (name) => name.replace(/\s+/g, '\u2212'),
  'repeated separators': (name) => name.replace(/\s+/g, '--'),
  'mixed separators': (name) => name.replace(/\s+/g, (_, offset) => (offset % 2 ? '_' : '-')),
};

function event(id, away, home, sport = 'NFL', startTime = '2026-11-08T18:00:00Z') {
  return {
    id,
    sport: { key: sport, label: sport },
    league: sport,
    startTime,
    endTime: null,
    away: { name: away, abbreviation: away.slice(0, 3).toUpperCase() },
    home: { name: home, abbreviation: home.slice(0, 3).toUpperCase() },
    status: { state: 'pre', detail: '' },
  };
}

describe('provider name variants', () => {
  it('resolves every curated team from every common provider spelling', () => {
    for (const canonical of Object.keys(ALIASES)) {
      const expected = normalizeTeamName(canonical);
      for (const [variant, render] of Object.entries(VARIANTS)) {
        assert.equal(
          resolveCanonical(render(canonical)),
          expected,
          `${variant} form of "${canonical}" did not resolve`,
        );
      }
    }
  });

  it('matches provider-mangled digit names ("4-9ers" → 49ers)', () => {
    const events = [event(
      'nfl-sf-lv', 'San Francisco 49ers', 'Las Vegas Raiders',
      'NFL', '2026-11-08T21:25:00Z',
    )];
    const r = matchStream('San-Francisco4-9ers @ LasVegas-Raiders', events);
    assert.equal(r.matched, true);
    assert.equal(r.event.id, 'nfl-sf-lv');
    assert.equal(r.confidence, 1);
  });

  it('tolerates a dropped plural suffix ("Boston Celtic")', () => {
    const events = [event('nba-bos-mil', 'Boston Celtics', 'Milwaukee Bucks', 'NBA')];
    const r = matchStream('BostonCeltic @ MilwaukeeBucks', events);
    assert.equal(r.matched, true);
    assert.equal(r.event.id, 'nba-bos-mil');
    assert.ok(r.confidence >= 0.5);
  });

  it('matches real events no matter how the provider spells either side', () => {
    const fixtures = [
      event('nfl-ind-dal', 'Indianapolis Colts', 'Dallas Cowboys'),
      event('nfl-phi-nyg', 'Philadelphia Eagles', 'New York Giants'),
      event('nfl-ne-gb', 'New England Patriots', 'Green Bay Packers'),
      event('nfl-lac-hou', 'Los Angeles Chargers', 'Houston Texans'),
      event('nba-bos-mil', 'Boston Celtics', 'Milwaukee Bucks', 'NBA'),
      event('nba-mia-sac', 'Miami Heat', 'Sacramento Kings', 'NBA'),
      event('nhl-njd-tbl', 'New Jersey Devils', 'Tampa Bay Lightning', 'NHL'),
      event('nhl-wpg-fla', 'Winnipeg Jets', 'Florida Panthers', 'NHL'),
    ];
    for (const ev of fixtures) {
      for (const [awayVariant, renderAway] of Object.entries(VARIANTS)) {
        for (const [homeVariant, renderHome] of Object.entries(VARIANTS)) {
          const tvgId = `${renderAway(ev.away.name)} @ ${renderHome(ev.home.name)}`;
          const r = matchStream(tvgId, [ev]);
          assert.equal(
            r.matched,
            true,
            `${awayVariant} away + ${homeVariant} home did not match: "${tvgId}"`,
          );
          assert.equal(r.event.id, ev.id, `wrong event for "${tvgId}"`);
          assert.equal(r.swapped, false, `unexpected swap for "${tvgId}"`);
          assert.ok(r.confidence >= 0.5, `low confidence for "${tvgId}": ${r.confidence}`);
        }
      }
    }
  });

  it('matches swapped home/away feeds with provider variants', () => {
    const events = [event('nfl-phi-nyg', 'Philadelphia Eagles', 'New York Giants')];
    const r = matchStream('NewYork-Giants @ Philadelphia-Eagles', events);
    assert.equal(r.matched, true);
    assert.equal(r.event.id, 'nfl-phi-nyg');
    assert.equal(r.swapped, true);
    assert.equal(r.confidence, 1);
  });

  it('does not over-match unrelated teams', () => {
    const events = [
      event('nfl-nyg-phi', 'New York Giants', 'Philadelphia Eagles'),
      event('mlb-nym-atl', 'New York Mets', 'Atlanta Braves'),
      event('mlb-nyy-bos', 'New York Yankees', 'Boston Red Sox'),
    ];
    assert.equal(matchStream('New York Jets @ Atlanta Falcons', events).matched, false);
    // Compact matching must not become a bag-of-words: concatenated but
    // reordered names are a different team, not a spelling variant.
    assert.equal(matchStream('YORKNEW @ SOXRED', events).matched, false);
    assert.equal(matchStream('San Francisco Giants @ Dallas Cowboys', events).matched, false);
  });

  it('keeps ambiguous alias precedence stable', () => {
    // These one-word aliases are carried by more than one team. The matcher
    // resolves them the same way as before (first curated entry wins) and
    // relies on event pairing to disambiguate; the compact index must not
    // change which team the bare alias points at.
    assert.equal(resolveCanonical('Giants'), 'san francisco giants');
    assert.equal(resolveCanonical('Kings'), 'sacramento kings');
    assert.equal(resolveCanonical('Rangers'), 'texas rangers');
    assert.equal(resolveCanonical('Panthers'), 'carolina panthers');
    assert.equal(resolveCanonical('Cardinals'), 'st louis cardinals');
  });
});
