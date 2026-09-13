const SUPABASE_URL = 'https://txipxisumngvzkuqsysq.supabase.co';
const SUPABASE_PUBLIC_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZ2dWpoa3J5cXpobWVtb2plZHhzIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODMzNDAwOTksImV4cCI6MjA5ODkxNjA5OX0.9TmFZBDBig8qG1iostl4-GoQL10CBgKSL_DvBHJ7lIc';

const SUPABASE_NEW_PUBLIC_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InR4aXB4aXN1bW5ndnprdXFzeXNxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODkwNzExMTYsImV4cCI6MjEwNDY0NzExNn0.NxrJIAkWWfg-5ezHni_z56IRmLD9HHxM-VAALiT22io';

async function rest(path) {
  const response = await fetch(`${SUPABASE_URL}${path}`, {
    headers: { apikey: SUPABASE_NEW_PUBLIC_KEY, Authorization: `Bearer ${SUPABASE_NEW_PUBLIC_KEY}` },
  });
  if (!response.ok) throw new Error(`League data request failed (${response.status}).`);
  return response.json();
}

const LEGACY_TEAM_MAP = {
  hms: ['5', '9', '24', '48'],
  jgr: ['11', '19', '20', '54'],
  penske: ['2', '12', '22'],
  '23xi': ['23', '35', '45'],
  rfk: ['6', '17', '60'],
  spire: ['7', '71', '77'],
  trackhouse: ['1', '88', '97'],
  legacy: ['42', '43', '84'],
};

export async function loadTeamCatalog() {
  const [{ data: teams, error: teamsError }, { data: numbers, error: numbersError }] = await Promise.all([
    rest('/rest/v1/n26_teams?select=id,slug,name,seat_limit,owner_name,honors&status=eq.active&order=name').then(data => ({ data, error: null })).catch(error => ({ data: null, error })),
    rest('/rest/v1/n26_team_car_numbers?select=team_id,car_number&is_available=eq.true&order=car_number').then(data => ({ data, error: null })).catch(error => ({ data: null, error })),
  ]);

  if (teamsError || numbersError) {
    return {
      teams: [],
      carNumbersByTeam: { ...LEGACY_TEAM_MAP },
      teamByCarNumber: Object.fromEntries(Object.entries(LEGACY_TEAM_MAP).flatMap(([team, cars]) => cars.map(car => [car, team]))),
      source: 'legacy-fallback',
    };
  }

  const teamById = Object.fromEntries((teams || []).map(team => [team.id, team]));
  const carNumbersByTeam = {};
  const teamByCarNumber = {};
  (numbers || []).forEach(({ team_id: teamId, car_number: carNumber }) => {
    const team = teamById[teamId];
    if (!team) return;
    if (!carNumbersByTeam[team.slug]) carNumbersByTeam[team.slug] = [];
    carNumbersByTeam[team.slug].push(String(carNumber));
    teamByCarNumber[String(carNumber)] = team.slug;
  });

  return { teams: teams || [], carNumbersByTeam, teamByCarNumber, source: 'normalized' };
}

export async function loadPublishedSeason() {
  try {
    const data = await rest('/rest/v1/n26_seasons?select=id,season_number,name,ruleset_id,status,rated_field_size,roster_lock_at,results_certified_at&status=in.(open,in_progress,appeal_window,certified,archived)&order=season_number.desc&limit=1');
    return data?.[0] || null;
  } catch { return null; }
}

export async function loadCurrentRosterSeason() {
  try {
    const data = await rest('/rest/v1/n26_seasons?select=id,season_number,name,ruleset_id,status,rated_field_size,roster_lock_at,results_certified_at&season_number=eq.1&order=season_number.desc&limit=1');
    return data?.[0] || null;
  } catch { return null; }
}

export async function loadSeasonRosterClaims(season) {
  const assignments = await rest(`/rest/v1/n26_seat_assignments?select=driver_id,team_id,car_number&season_id=eq.${season.id}&assignment_status=eq.active`);
  const driverIds = [...new Set((assignments || []).map(assignment => assignment.driver_id))];
  const drivers = driverIds.length
    ? await rest(`/rest/v1/n26_drivers?select=id,display_name,gamertag,first_name,last_name&id=in.(${driverIds.join(',')})`)
    : [];
  const driversById = Object.fromEntries((drivers || []).map(driver => [driver.id, driver]));

  return (assignments || []).map(assignment => {
    const driver = driversById[assignment.driver_id] || {};
    return {
      car_number: String(assignment.car_number),
      gamertag: driver.gamertag || driver.display_name || `Car #${assignment.car_number}`,
      first_name: driver.first_name || '',
      last_name: driver.last_name || '',
      driver_id: assignment.driver_id,
      team_id: assignment.team_id,
    };
  });
}

export async function loadNormalizedSeasonData(season) {
  const [rulesetRows, races, entries, assignments, results, ratings] = await Promise.all([
    rest(`/rest/v1/n26_rulesets?select=*&id=eq.${season.ruleset_id}&limit=1`),
    rest(`/rest/v1/n26_season_races?select=*&season_id=eq.${season.id}&order=race_number`),
    rest(`/rest/v1/n26_season_entries?select=*&season_id=eq.${season.id}`),
    rest(`/rest/v1/n26_seat_assignments?select=*&season_id=eq.${season.id}&assignment_status=eq.active`),
    rest('/rest/v1/n26_race_results?select=*&certification_status=in.(published,certified)'),
    rest(`/rest/v1/n26_rating_snapshots?select=*&season_id=eq.${season.id}&certification_status=eq.certified`),
  ]);

  const driverIds = [...new Set([
    ...(entries || []).map(entry => entry.driver_id),
    ...(assignments || []).map(assignment => assignment.driver_id),
    ...(ratings || []).map(rating => rating.driver_id),
  ])];
  if (!rulesetRows?.[0]) throw new Error('Published season ruleset is unavailable.');
  const driversResponse = driverIds.length
    ? await rest(`/rest/v1/n26_drivers?select=id,display_name,gamertag,first_name,last_name&id=in.(${driverIds.join(',')})`)
    : [];

  return {
    source: 'normalized',
    season,
    ruleset: rulesetRows?.[0] || null,
    races: races || [],
    entries: entries || [],
    assignments: assignments || [],
    results: (results || []).filter(result => (races || []).some(race => race.id === result.race_id)),
    ratings: ratings || [],
    drivers: driversResponse || [],
  };
}

export async function loadLegacySeasonData() {
  const [races, claims, results] = await Promise.all([
    rest('/rest/v1/n26_races?select=*&order=race_number'),
    rest('/rest/v1/n26_claim_roster?select=car_number,gamertag,first_name,last_name'),
    rest('/rest/v1/n26_results?select=*'),
  ]);

  // Keep this compatibility loader available for migrations and diagnostics.
  // It is not used as the current public prelaunch state; the old table also
  // contains retired chase rounds.
  const rulebookRaces = (races || []).slice(0, 8).map(race => ({ ...race, race_type: 'regular' }));
  const rulebookRaceIds = new Set(rulebookRaces.map(race => race.id));

  return {
    source: 'legacy',
    season: { season_number: 1, name: 'Season 1', status: 'legacy' },
    races: rulebookRaces,
    claims: claims || [],
    results: (results || []).filter(result => rulebookRaceIds.has(result.race_id)),
  };
}

export async function loadPublicLeagueData() {
  const catalog = await loadTeamCatalog();
  const season = await loadPublishedSeason();
  let news = [];
  try { news = await rest('/rest/v1/n26_news_articles?select=id,headline,dek,body,image_url,published_at&status=eq.published&order=published_at.desc&limit=6'); } catch { news = []; }
  if (!season) {
    return {
      source: 'prelaunch',
      season: { season_number: 1, name: 'Season 1', status: 'prelaunch' },
      races: [],
      claims: [],
      results: [],
      catalog,
      news,
    };
  }
  return { ...(await loadNormalizedSeasonData(season)), catalog, news };
}

export function toLegacyDisplayData(data) {
  if (data.source === 'legacy') return data;

  const drivers = Object.fromEntries((data.drivers || []).map(driver => [driver.id, driver]));
  const teams = Object.fromEntries((data.catalog?.teams || []).map(team => [team.id, team.name]));
  const assignments = data.assignments || [];
  const claims = assignments.map(assignment => {
    const driver = drivers[assignment.driver_id] || {};
    return {
      car_number: assignment.car_number,
      gamertag: driver.gamertag || driver.display_name || `Car #${assignment.car_number}`,
      first_name: driver.first_name || '',
      last_name: driver.last_name || '',
      driver_id: assignment.driver_id,
      team_id: assignment.team_id,
      team_name: teams[assignment.team_id] || '',
    };
  });

  return {
    ...data,
    claims,
    races: (data.races || []).map(race => ({
      id: race.id,
      race_number: race.race_number,
      track_name: race.track_name,
      track_short: race.track_short,
      race_type: race.race_type,
      race_date: race.race_date,
      status: race.status,
      certification_status: race.certification_status,
      published_at: race.published_at,
      appeal_ends_at: race.appeal_ends_at,
      voided_at: race.voided_at,
      void_reason: race.void_reason,
    })),
    results: (data.results || []).map(result => ({
      ...result,
      race_id: result.race_id,
      team_name: teams[result.team_id] || '',
      car_number: result.car_number,
      finish_position: result.finish_position,
      points_earned: result.points_earned,
      stage1_points: result.stage1_points || 0,
      stage2_points: result.stage2_points || 0,
      dnf: result.finish_status === 'dnf',
      disqualified: result.finish_status === 'disqualified',
      stage1_points: 0,
      stage2_points: 0,
      playoff_points: 0,
    })),
  };
}
