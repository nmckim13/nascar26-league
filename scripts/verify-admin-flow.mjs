import assert from 'node:assert/strict';

process.env.SUPABASE_URL = 'https://league-test.invalid';
process.env.SUPABASE_SERVICE_ROLE_KEY = 'test-only';
const { default: handler } = await import('../api/league-admin.js');

let season;
let races;
const originalFetch = globalThis.fetch;
globalThis.fetch = async (input, options = {}) => {
  const url = new URL(input);
  if (url.pathname === '/auth/v1/user') return Response.json({ id: 'commissioner' });
  if (url.pathname === '/rest/v1/rpc/is_admin') return Response.json(true);
  const row = url.pathname === '/rest/v1/n26_seasons' ? season
    : races.find(race => `eq.${race.id}` === url.searchParams.get('id'));
  assert.ok(row, `Unexpected request: ${url}`);
  if (options.method === 'PATCH') {
    if (!url.searchParams.has('status') || url.searchParams.get('status') === `eq.${row.status}`) {
      Object.assign(row, JSON.parse(options.body));
    }
    return new Response(null, { status: 204 });
  }
  return Response.json([row]);
};

async function openRace(id) {
  let status;
  let body;
  await handler({ method: 'POST', headers: { authorization: 'Bearer test' }, body: { action: 'open_race', race_id: id } }, {
    status(value) { status = value; return this; },
    json(value) { body = value; },
  });
  return { status, body };
}

try {
  season = { id: 'season', status: 'open', roster_lock_at: '2026-09-27T18:00:00Z' };
  races = [1, 2].map(id => ({ id: `race-${id}`, season_id: season.id, status: 'upcoming', certification_status: 'draft' }));
  assert.equal((await openRace('race-1')).status, 200);
  assert.equal(season.status, 'in_progress');
  races[0].status = 'completed';
  races[0].certification_status = 'certified';
  const secondRound = await openRace('race-2');
  assert.equal(secondRound.status, 200, secondRound.body.error);
  assert.equal(races[1].status, 'open');
  assert.equal(season.status, 'in_progress');

  for (const status of ['draft', 'certified', 'archived']) {
    season.status = status;
    races[1].status = 'upcoming';
    const result = await openRace('race-2');
    assert.equal(result.body.ok, false);
    assert.match(result.body.error, /Publish the season before opening a race/);
    assert.equal(races[1].status, 'upcoming');
    assert.equal(season.status, status);
  }
  season.status = 'in_progress';
  season.roster_lock_at = null;
  const unlocked = await openRace('race-2');
  assert.equal(unlocked.body.ok, false);
  assert.match(unlocked.body.error, /Publish the season before opening a race/);
  assert.equal(races[1].status, 'upcoming');
  season.roster_lock_at = '2026-09-27T18:00:00Z';
  for (const [status, certification] of [['completed', 'certified'], ['voided', 'certified'], ['open', 'draft'], ['upcoming', 'published']]) {
    Object.assign(races[1], { status, certification_status: certification });
    const result = await openRace('race-2');
    assert.equal(result.body.ok, false);
    assert.match(result.body.error, /Only an upcoming draft race can be opened/);
    assert.equal(races[1].status, status);
    assert.equal(races[1].certification_status, certification);
  }
  console.log('Admin race opening verified: consecutive rounds, season lock, and closed race/season guards.');
} finally {
  globalThis.fetch = originalFetch;
}
