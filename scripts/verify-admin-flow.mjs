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

// The database owns recap publication. Subsequent API storyline generation
// must not overwrite that published article with an obsolete draft.
try {
  const recap = { headline: 'Corrected winner at Dover', status: 'published', published_at: '2026-10-27T18:00:00Z' };
  const expectedRecap = { ...recap };
  const race = { id: 'race', season_id: 'season', race_number: 6, track_name: 'Dover', status: 'completed', certification_status: 'appeal_window', race_type: 'championship', starters_count: 2 };
  const results = [
    { driver_id: 'winner', car_number: '88', finish_position: 1, finish_status: 'classified', start_status: 'started', points_earned: 55, certification_status: 'published' },
    { driver_id: 'second', car_number: '20', finish_position: 2, finish_status: 'classified', start_status: 'started', points_earned: 35, certification_status: 'published' },
  ];
  globalThis.fetch = async (input, options = {}) => {
    const path = new URL(input).pathname;
    if (path === '/auth/v1/user') return Response.json({ id: 'commissioner' });
    if (path === '/rest/v1/rpc/is_admin') return Response.json(true);
    if (path === '/rest/v1/rpc/n26_upsert_race_results' || path === '/rest/v1/rpc/n26_correct_race_results') return Response.json(2);
    if (path === '/rest/v1/n26_seasons') return Response.json([{ id: 'season', ruleset_id: 'rules' }]);
    if (path === '/rest/v1/n26_rulesets') return Response.json([{ id: 'rules', points_by_position: { 1: 55, 2: 35 }, config: {} }]);
    if (path === '/rest/v1/n26_season_entries') return Response.json(results.map(result => ({ driver_id: result.driver_id, entry_status: 'full_time' })));
    if (path === '/rest/v1/n26_season_races') return Response.json([race]);
    if (path === '/rest/v1/n26_race_results') return Response.json(results.map(result => ({ ...result, race_id: race.id })));
    if (path === '/rest/v1/n26_drivers') return Response.json([{ id: 'winner', display_name: 'Nolan McKim' }, { id: 'second', display_name: 'Logan Boone' }]);
    if (path === '/rest/v1/n26_storylines') return Response.json(JSON.parse(options.body));
    if (path === '/rest/v1/n26_news_articles') {
      Object.assign(recap, JSON.parse(options.body));
      return Response.json([recap]);
    }
    throw new Error(`Unexpected request: ${input}`);
  };
  for (const action of ['record_results', 'correct_results']) {
    let response;
    let status;
    await handler({ method: 'POST', headers: { authorization: 'Bearer test' }, body: { action, race_id: race.id, results } }, {
      status(value) { status = value; return this; },
      json(value) { response = value; },
    });
    assert.equal(status, 200, response.error);
    assert.equal(response.result.results, 2);
    assert.equal(response.result.generated.storyline_count, 3);
    assert.deepEqual(recap, expectedRecap, `${action} overwrote the public recap`);
  }
  console.log('Admin result saves/corrections verified: storyline drafts do not overwrite published recaps.');
} finally {
  globalThis.fetch = originalFetch;
}

// Raw totals favor the regular-season winner, but the Chase makes the other
// driver champion. Ratings must use that championship order, not raw awards.
try {
  const races = Array.from({ length: 10 }, (_, index) => ({ id: `race-${index + 1}`,
    race_number: index + 1, season_id: 'season', status: 'completed', starters_count: 2,
    race_type: index < 7 ? 'regular' : 'chase', qualifying_status: 'canceled', certification_status: 'certified' }));
  const results = races.flatMap((race, index) => ['regular-winner', 'chase-winner'].map((driver_id, driver) => {
    const first = index < 7 ? driver === 0 : driver === 1;
    return { id: `${race.id}-${driver}`, race_id: race.id, driver_id, start_status: 'started',
      finish_position: first ? 1 : 2, points_earned: first ? 55 : 35, certification_status: 'certified', source_version: 1 };
  }));
  const tables = {
    n26_seasons: [{ id: 'season', ruleset_id: 'rules', season_number: 2, rated_field_size: 2 }],
    n26_rulesets: [{ id: 'rules', points_by_position: { 1: 55, 2: 35 }, config: { championship_format: 'chase_12_7_3' } }],
    n26_season_races: races, n26_race_results: results,
    n26_season_entries: ['regular-winner', 'chase-winner'].map(driver_id => ({ driver_id, entry_status: 'full_time' })),
  };
  globalThis.fetch = async (input, options = {}) => {
    const path = new URL(input).pathname;
    if (path === '/auth/v1/user') return Response.json({ id: 'commissioner' });
    if (path === '/rest/v1/rpc/is_admin') return Response.json(true);
    if (path === '/rest/v1/n26_rating_snapshots') return Response.json(JSON.parse(options.body));
    return Response.json(tables[path.split('/').pop()] || []);
  };
  let response;
  let status;
  await handler({ method: 'POST', headers: { authorization: 'Bearer test' }, body: { action: 'calculate_ratings', season_id: 'season' } }, {
    status(value) { status = value; return this; }, json(value) { response = value; },
  });
  assert.equal(status, 200, response.error);
  assert.deepEqual(response.result.standings.drivers.map(driver => [driver.driverId, driver.points]),
    [['chase-winner', 2240], ['regular-winner', 2205]]);
  assert.equal(response.result.snapshots.find(row => row.driver_id === 'chase-winner').championship_finish, 100);
  assert.ok(Math.abs(response.result.snapshots.find(row => row.driver_id === 'regular-winner').championship_finish
    - (40 + 60 / Math.sqrt(2))) < 1e-10); // Second of two: 40 + 60√(1/2).
  console.log('Admin ratings verified: Season 2 Chase order drives championship rating credits instead of raw season totals.');
} finally {
  globalThis.fetch = originalFetch;
}
