import test from 'node:test';
import assert from 'node:assert/strict';
import { planFixes } from '../src/sync.js';

const channels = [
  { id: 1, name: 'NESN 2', epg_data_id: 999 },
  { id: 2, name: 'NBC Sports Philadelphia', epg_data_id: 42 },
  { id: 3, name: 'NBC Sports California', epg_data_id: 42 },
  { id: 4, name: 'Already OK', epg_data_id: 7 },
];
const epgData = [
  { id: 7, tvg_id: 'NESN.us' },
  { id: 8, tvg_id: 'NBCSPhiladelphia.us' },
  { id: 9, tvg_id: 'NBCSCalifornia.us' },
];
const fixes = [
  { channelName: 'NESN 2', xmltvId: 'NESN.us', reason: 'mis-mapped' },
  { channelName: 'NBC Sports Philadelphia', xmltvId: 'NBCSPhiladelphia.us', reason: 'mis-mapped' },
  { channelName: 'NBC Sports California', xmltvId: 'NBCSCalifornia.us', reason: 'mis-mapped' },
  { channelName: 'Already OK', xmltvId: 'NESN.us', reason: 'noop' },
  { channelName: 'Missing Channel', xmltvId: 'NESN.us', reason: 'skip' },
  { channelName: 'NESN 2', xmltvId: 'NOPE.us', reason: 'skip' },
];

test('planFixes patches only mismatches and reports missing refs', () => {
  const { planned, missing } = planFixes(channels, epgData, fixes);
  assert.deepEqual(planned.map((p) => [p.channelName, p.from, p.to]), [
    ['NESN 2', 999, 7],
    ['NBC Sports Philadelphia', 42, 8],
    ['NBC Sports California', 42, 9],
  ]);
  assert.equal(missing.length, 2);
  assert.ok(missing.some((m) => m.channelName === 'Missing Channel'));
  assert.ok(missing.some((m) => m.xmltvId === 'NOPE.us'));
});

test('planFixes is idempotent on correct mappings', () => {
  const ok = channels.map((c) => (c.id === 1 ? { ...c, epg_data_id: 7 } : c));
  const { planned } = planFixes(ok, epgData, fixes.slice(0, 1));
  assert.equal(planned.length, 0);
});

test('planFixes never fabricates data for empty inputs', () => {
  assert.deepEqual(planFixes([], [], fixes), { planned: [], missing: fixes.map((f) => ({ ...f, reasonMissing: 'channel not found' })) });
});
