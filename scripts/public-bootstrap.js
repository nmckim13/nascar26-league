(function () {
  const SUPABASE_URL = 'https://txipxisumngvzkuqsysq.supabase.co';
  const SUPABASE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZ2dWpoa3J5cXpobWVtb2plZHhzIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODMzNDAwOTksImV4cCI6MjA5ODkxNjA5OX0.9TmFZBDBig8qG1iostl4-GoQL10CBgKSL_DvBHJ7lIc';
  const SUPABASE_NEW_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InR4aXB4aXN1bW5ndnprdXFzeXNxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODkwNzExMTYsImV4cCI6MjEwNDY0NzExNn0.NxrJIAkWWfg-5ezHni_z56IRmLD9HHxM-VAALiT22io';
  const headers = { apikey: SUPABASE_NEW_KEY, Authorization: 'Bearer ' + SUPABASE_NEW_KEY };

  async function rest(path) {
    const response = await fetch(SUPABASE_URL + path, { headers });
    if (!response.ok) throw new Error('League data request failed (' + response.status + ').');
    return response.json();
  }

  async function loadLegacy() {
    const values = await Promise.all([
      rest('/rest/v1/n26_races?select=*&order=race_number'),
      rest('/rest/v1/n26_claim_roster?select=car_number,gamertag,first_name,last_name'),
      rest('/rest/v1/n26_results?select=*'),
    ]);
    const races = (values[0] || []).slice(0, 8).map(function (race) { return { ...race, race_type: 'regular' }; });
    const raceIds = new Set(races.map(function (race) { return race.id; }));
    return { source: 'legacy', season: { season_number: 1, name: 'Season 1', status: 'legacy' }, races, claims: values[1], results: (values[2] || []).filter(function (result) { return raceIds.has(result.race_id); }), catalog: null };
  }

  async function loadCatalog() {
    const values = await Promise.all([
      rest('/rest/v1/n26_teams?select=id,name,slug,owner_name,honors&status=eq.active&order=name'),
      rest('/rest/v1/n26_team_car_numbers?select=team_id,car_number&is_available=eq.true&order=car_number'),
    ]);
    return {
      teams: values[0],
      carNumbers: values[1],
    };
  }

  async function load() {
    const news = await rest('/rest/v1/n26_news_articles?select=id,headline,dek,body,image_url,published_at&status=eq.published&order=published_at.desc&limit=6').catch(function () { return []; });
    const seasons = await rest('/rest/v1/n26_seasons?select=id,season_number,name,ruleset_id,status,rated_field_size,roster_lock_at,results_certified_at&status=in.(draft,open,in_progress,appeal_window,certified,archived)&order=season_number.desc&limit=1');
    const catalog = await loadCatalog().catch(function () { return null; });
    if (!seasons.length) {
      return {
        source: 'prelaunch',
        season: { season_number: 1, name: 'Season 1', status: 'prelaunch' },
        races: [],
        claims: [],
        results: [],
        catalog, news,
      };
    }
    const season = seasons[0];
    if (season.status === 'draft') {
      return {
        source: 'prelaunch',
        season,
        races: [],
        claims: [],
        results: [],
        catalog,
        news,
      };
    }
    const values = await Promise.all([
      rest('/rest/v1/n26_rulesets?select=*&id=eq.' + season.ruleset_id + '&limit=1'),
      rest('/rest/v1/n26_season_races?select=*&season_id=eq.' + season.id + '&order=race_number'),
      rest('/rest/v1/n26_season_entries?select=*&season_id=eq.' + season.id),
      rest('/rest/v1/n26_seat_assignments?select=*&season_id=eq.' + season.id + '&assignment_status=eq.active'),
      rest('/rest/v1/n26_race_results?select=*&certification_status=in.(published,certified)'),
      rest('/rest/v1/n26_rating_snapshots?select=*&season_id=eq.' + season.id + '&certification_status=eq.certified'),
    ]);
    if (!values[0][0]) throw new Error('Published season ruleset is unavailable.');
    const driverIds = [...new Set(values[2].map(entry => entry.driver_id).concat(values[3].map(assignment => assignment.driver_id), values[5].map(rating => rating.driver_id)))];
    const drivers = driverIds.length ? await rest('/rest/v1/n26_drivers?select=id,display_name,gamertag,first_name,last_name&id=in.(' + driverIds.join(',') + ')') : [];
    return {
      source: 'normalized', season, ruleset: values[0][0] || null, races: values[1], entries: values[2], assignments: values[3],
      results: values[4].filter(result => values[1].some(race => race.id === result.race_id)), ratings: values[5], drivers, catalog, news,
    };
  }

  function display(data) {
    if (data.source === 'legacy') return data;
    const drivers = Object.fromEntries(data.drivers.map(driver => [driver.id, driver]));
    const teams = Object.fromEntries((data.catalog?.teams || []).map(team => [team.id, team.name]));
    return {
      ...data,
      claims: data.assignments.map(assignment => {
        const driver = drivers[assignment.driver_id] || {};
        return { car_number: assignment.car_number, gamertag: driver.gamertag || driver.display_name || 'Car #' + assignment.car_number, first_name: driver.first_name || '', last_name: driver.last_name || '', driver_id: assignment.driver_id, team_id: assignment.team_id, team_name: teams[assignment.team_id] || '' };
      }),
      races: data.races.map(race => ({ id: race.id, race_number: race.race_number, track_name: race.track_name, track_short: race.track_short, race_type: race.race_type, race_date: race.race_date, status: race.status, certification_status: race.certification_status, published_at: race.published_at, appeal_ends_at: race.appeal_ends_at, voided_at: race.voided_at, void_reason: race.void_reason })),
      results: data.results.map(result => ({ ...result, race_id: result.race_id, car_number: result.car_number, team_name: teams[result.team_id] || '', finish_position: result.finish_position, points_earned: result.points_earned, dnf: result.finish_status === 'dnf', disqualified: result.finish_status === 'disqualified', stage1_points: result.stage1_points || 0, stage2_points: result.stage2_points || 0, playoff_points: 0 })),
    };
  }

  window.__leagueDataReady = load().then(display).catch(function (error) {
    console.error('Normalized league data unavailable; showing prelaunch state.', error);
    return {
      source: 'prelaunch',
      season: { season_number: 1, name: 'Season 1', status: 'prelaunch' },
      races: [],
      claims: [],
      results: [],
      catalog: null,
      news: [],
    };
  });
}());
