import { createHash } from 'node:crypto';
import rules from '../scripts/league-rules.js';

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

function json(res, status, body) {
  return res.status(status).json(body);
}

function requireConfig() {
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    const error = new Error('Supabase server configuration is incomplete.');
    error.status = 503;
    throw error;
  }
}

async function supabaseRequest(path, options = {}) {
  const headers = {
    apikey: SUPABASE_SERVICE_ROLE_KEY,
    Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
    'Content-Type': 'application/json',
    ...(options.headers || {}),
  };
  const response = await fetch(`${SUPABASE_URL}${path}`, { ...options, headers });
  const text = await response.text();
  let body = null;
  try { body = text ? JSON.parse(text) : null; } catch { body = text; }
  if (!response.ok) {
    const message = body?.message || body?.error_description || body?.hint || body?.details || body?.error || 'Supabase request failed';
    const error = new Error(message);
    error.status = response.status;
    error.details = body;
    throw error;
  }
  return body;
}

async function requireAdmin(req) {
  const authorization = req.headers.authorization || '';
  if (!authorization.startsWith('Bearer ')) {
    const error = new Error('Sign-in required.');
    error.status = 401;
    throw error;
  }
  requireConfig();
  const token = authorization.slice('Bearer '.length).trim();
  const userResponse = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { apikey: SUPABASE_SERVICE_ROLE_KEY, Authorization: `Bearer ${token}` },
  });
  if (!userResponse.ok) {
    const error = new Error('Invalid or expired session.');
    error.status = 401;
    throw error;
  }
  const user = await userResponse.json();
  const adminResponse = await fetch(`${SUPABASE_URL}/rest/v1/rpc/is_admin`, {
    method: 'POST',
    headers: {
      apikey: SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: '{}',
  });
  const isAdmin = adminResponse.ok && (await adminResponse.json()) === true;
  if (!isAdmin) {
    const error = new Error('Commissioner access required.');
    error.status = 403;
    throw error;
  }
  return user;
}

async function rpc(name, args) {
  return supabaseRequest(`/rest/v1/rpc/${name}`, {
    method: 'POST',
    body: JSON.stringify(args),
  });
}

async function getSeason(seasonId) {
  const query = seasonId ? `?id=eq.${encodeURIComponent(seasonId)}&select=*` : '?order=season_number.desc&limit=1&select=*';
  const rows = await supabaseRequest(`/rest/v1/n26_seasons${query}`);
  if (!rows?.length) throw Object.assign(new Error('Season not found.'), { status: 404 });
  return rows[0];
}

async function getSeasonBundle(seasonId) {
  const season = await getSeason(seasonId);
  const raceRows = await supabaseRequest(`/rest/v1/n26_season_races?season_id=eq.${season.id}&select=id`);
  const [rulesetRows, races, entries, assignments, results, drivers, teams, catalog, applications] = await Promise.all([
    supabaseRequest(`/rest/v1/n26_rulesets?id=eq.${season.ruleset_id}&select=*`),
    supabaseRequest(`/rest/v1/n26_season_races?season_id=eq.${season.id}&order=race_number&select=*`),
    supabaseRequest(`/rest/v1/n26_season_entries?season_id=eq.${season.id}&select=*`),
    supabaseRequest(`/rest/v1/n26_seat_assignments?season_id=eq.${season.id}&select=*`),
    supabaseRequest(`/rest/v1/n26_race_results?race_id=in.(${raceRows.map(race => race.id).join(',') || '00000000-0000-0000-0000-000000000000'})&select=*`),
    supabaseRequest('/rest/v1/n26_drivers?select=*'),
    supabaseRequest('/rest/v1/n26_teams?status=eq.active&select=id,name,slug,seat_limit,owner_name,honors&order=name'),
    supabaseRequest('/rest/v1/n26_team_car_numbers?is_available=eq.true&select=team_id,car_number&order=car_number'),
    supabaseRequest('/rest/v1/n26_claims?select=id,user_id,car_number,team_name,gamertag,first_name,last_name,phone,discord_username,approval_status,claimed_at,reviewed_at&order=claimed_at.desc'),
  ]);
  if (!rulesetRows?.length) throw new Error('Season ruleset not found.');
  const contracts = await supabaseRequest(`/rest/v1/n26_contracts?start_season=lte.${season.season_number}&end_season=gte.${season.season_number}&status=in.(introductory,active)&order=created_at.desc&select=*`);
  return { season, ruleset: rulesetRows[0], races, entries, assignments, results, drivers, teams, catalog, contracts, applications };
}

function makeResultsVersion(bundle) {
  const source = bundle.results.filter(result => result.certification_status === 'certified').map(result => [result.id, result.source_version].join(':')).sort().join('|');
  return `results-${createHash('sha256').update(source).digest('hex').slice(0, 16)}`;
}

async function calculateRatings(seasonId) {
  const bundle = await getSeasonBundle(seasonId);
  const activeEntries = bundle.entries.filter(entry => entry.entry_status === 'full_time');
  if (!activeEntries.length) throw new Error('The season has no full-time entries.');
  const ratedFieldSize = Number(bundle.season.rated_field_size || activeEntries.length);
  if (!Number.isInteger(ratedFieldSize) || ratedFieldSize < activeEntries.length) {
    throw new Error('The season rated-field snapshot is invalid.');
  }
  const pointsByPosition = bundle.ruleset.points_by_position;
  const standings = rules.calculateSeasonStandings({
    entries: activeEntries.map(entry => ({ driverId: entry.driver_id, teamId: null, entryStatus: entry.entry_status })),
    races: bundle.races,
    results: bundle.results.filter(result => result.certification_status === 'certified'),
    pointsByPosition,
    strict: true,
  });
  const sourceResultsVersion = makeResultsVersion(bundle);
  const snapshots = standings.drivers.map(driver => {
    const rating = rules.calculateRating({
      rank: driver.ratingRank,
      fieldSize: ratedFieldSize,
      seasonLength: standings.completedRaces.length,
      starts: driver.starts,
      wins: driver.wins,
      finishCredits: driver.finishCredits,
      qualifyingCredits: driver.qualifyingCredits,
      qualifyingRounds: driver.qualifyingRounds,
    }, bundle.ruleset.rating_weights);
    return {
      season_id: bundle.season.id,
      driver_id: driver.driverId,
      ruleset_id: bundle.ruleset.id,
      rated_field_size: ratedFieldSize,
      championship_finish: rating.championshipFinish,
      finish_quality: rating.finishQuality,
      wins_rating: rating.wins,
      attendance: rating.attendance,
      qualifying: rating.qualifying,
      overall_raw: rating.overallRaw,
      official_ovr: rating.overall,
      source_results_version: sourceResultsVersion,
      certification_status: 'provisional',
    };
  });
  if (snapshots.length) {
    await supabaseRequest('/rest/v1/n26_rating_snapshots?on_conflict=season_id,driver_id,certification_status', {
      method: 'POST',
      headers: { Prefer: 'resolution=merge-duplicates,return=representation' },
      body: JSON.stringify(snapshots),
    });
  }
  return { season: bundle.season, snapshots, standings };
}

async function handleAction(action, body, user) {
  switch (action) {
    case 'overview':
      return getSeasonBundle(body.season_id);
    case 'approve_application': {
      if (!body.application_id || !body.season_id) throw new Error('An application and draft season are required.');
      return rpc('n26_review_claim', {
        p_claim_id: body.application_id,
        p_decision: 'approved',
        p_reviewer: user.id,
        p_season_id: body.season_id,
      });
    }
    case 'reject_application': {
      if (!body.application_id) throw new Error('An application is required.');
      return rpc('n26_review_claim', {
        p_claim_id: body.application_id,
        p_decision: 'rejected',
        p_reviewer: user.id,
        p_season_id: body.season_id || null,
      });
    }
    case 'create_driver': {
      if (!body.display_name || String(body.display_name).trim().length < 2) throw new Error('Display name is required.');
      const created = await rpc('n26_create_driver', {
        p_display_name: String(body.display_name).trim(),
        p_gamertag: body.gamertag ? String(body.gamertag).trim() : null,
        p_first_name: body.first_name ? String(body.first_name).trim() : null,
        p_last_name: body.last_name ? String(body.last_name).trim() : null,
        p_status: body.status === 'reserve' ? 'reserve' : 'active',
        p_season_id: body.season_id || null,
        p_entry_status: body.entry_status === 'reserve' || body.status === 'reserve' ? 'reserve' : 'full_time',
      });
      return Array.isArray(created) ? created[0] : created;
    }
    case 'update_team_profile': {
      if (!body.team_id) throw new Error('A team is required.');
      const honors = body.honors === undefined ? [] : body.honors;
      if (!Array.isArray(honors) || honors.length > 50) throw new Error('Honors must be an array with no more than 50 items.');
      if (honors.some(honor => typeof honor !== 'string' && (!honor || typeof honor !== 'object' || Array.isArray(honor)))) {
        throw new Error('Each honor must be a string or an object.');
      }
      const updated = await supabaseRequest(`/rest/v1/n26_teams?id=eq.${encodeURIComponent(body.team_id)}`, {
        method: 'PATCH',
        headers: { Prefer: 'return=representation' },
        body: JSON.stringify({
          owner_name: body.owner_name ? String(body.owner_name).trim() : null,
          honors,
        }),
      });
      if (!updated.length) throw Object.assign(new Error('Team not found.'), { status: 404 });
      return updated[0];
    }
    case 'import_roster':
      if (!body.season_id || !Array.isArray(body.roster) || body.roster.length === 0) {
        throw new Error('A season and a non-empty roster array are required.');
      }
      return rpc('n26_import_roster', {
        p_season_id: body.season_id,
        p_roster: body.roster,
      });
    case 'sync_claims':
      if (!body.season_id) throw new Error('A draft season is required.');
      return rpc('n26_sync_claims_to_draft', { p_season_id: body.season_id });
    case 'approve_points_schedule':
      if (!body.season_id || !body.version || !body.points_by_position || typeof body.points_by_position !== 'object' || Array.isArray(body.points_by_position)) {
        throw new Error('A season, ruleset version, and points object are required.');
      }
      return rpc('n26_approve_points_schedule', {
        p_season_id: body.season_id,
        p_version: String(body.version).trim(),
        p_points_by_position: body.points_by_position,
      });
    case 'assign_seat':
      if (body.allow_transfer === true) {
        return rpc('n26_transfer_driver_to_seat', {
          p_season_id: body.season_id,
          p_driver_id: body.driver_id,
          p_team_id: body.team_id,
          p_car_number: String(body.car_number),
          p_driver_consented: body.driver_consented === true,
          p_from_team_consented: body.from_team_consented === true,
          p_to_team_consented: body.to_team_consented === true,
          p_notes: body.notes ? String(body.notes).trim() : null,
        });
      }
      return rpc('n26_assign_driver_to_seat', {
        p_season_id: body.season_id,
        p_driver_id: body.driver_id,
        p_team_id: body.team_id,
        p_car_number: String(body.car_number),
        p_allow_transfer: body.allow_transfer === true,
      });
    case 'replace_driver_midseason':
      if (!body.season_id || !body.departing_driver_id || !body.replacement_driver_id || !body.reason) {
        throw new Error('A season, departing driver, replacement driver, and documented reason are required.');
      }
      return rpc('n26_replace_driver_midseason', {
        p_season_id: body.season_id,
        p_departing_driver_id: body.departing_driver_id,
        p_replacement_driver_id: body.replacement_driver_id,
        p_reason: String(body.reason).trim(),
      });
    case 'release_seat':
      return rpc('n26_release_driver_from_seat', {
        p_season_id: body.season_id,
        p_driver_id: body.driver_id,
        p_notes: body.notes || null,
      });
    case 'configure_race': {
      const allowed = ['track_name', 'track_short', 'race_date', 'starters_count', 'qualifying_field_count', 'qualifying_status'];
      const updates = Object.fromEntries(allowed.filter(key => body[key] !== undefined).map(key => [key, body[key]]));
      if (updates.starters_count !== undefined) updates.starters_count = Number(updates.starters_count);
      if (updates.qualifying_field_count !== undefined) updates.qualifying_field_count = Number(updates.qualifying_field_count);
      if (!Object.keys(updates).length) throw new Error('No race fields were provided.');
      const rows = await supabaseRequest(`/rest/v1/n26_season_races?id=eq.${encodeURIComponent(body.race_id)}&select=*`);
      if (!rows.length) throw Object.assign(new Error('Race not found.'), { status: 404 });
      if (rows[0].status === 'completed' || rows[0].certification_status !== 'draft') throw new Error('Published or completed races cannot be reconfigured.');
      const updated = await supabaseRequest(`/rest/v1/n26_season_races?id=eq.${encodeURIComponent(body.race_id)}`, { method: 'PATCH', headers: { Prefer: 'return=representation' }, body: JSON.stringify(updates) });
      return updated[0];
    }
    case 'open_race': {
      const raceId = encodeURIComponent(body.race_id);
      const rows = await supabaseRequest(`/rest/v1/n26_season_races?id=eq.${raceId}&select=season_id,status,certification_status`);
      if (!rows.length) throw Object.assign(new Error('Race not found.'), { status: 404 });
      if (rows[0].status !== 'upcoming' || rows[0].certification_status !== 'draft') throw new Error('Only an upcoming draft race can be opened.');
      const season = await getSeason(rows[0].season_id);
      if (season.status !== 'open' || season.roster_lock_at === null) throw new Error('Publish the season before opening a race.');
      await supabaseRequest(`/rest/v1/n26_season_races?id=eq.${raceId}`, { method: 'PATCH', headers: { Prefer: 'return=minimal' }, body: JSON.stringify({ status: 'open' }) });
      await supabaseRequest(`/rest/v1/n26_seasons?id=eq.${encodeURIComponent(rows[0].season_id)}&status=eq.open`, { method: 'PATCH', headers: { Prefer: 'return=minimal' }, body: JSON.stringify({ status: 'in_progress' }) });
      return { race_id: body.race_id, status: 'open' };
    }
    case 'void_race':
      if (!body.reason || String(body.reason).trim().length < 3) throw new Error('A reason is required to void a race.');
      return rpc('n26_void_race', { p_race_id: body.race_id, p_reason: String(body.reason).trim() });
    case 'record_results':
      return rpc('n26_upsert_race_results_with_stages', {
        p_race_id: body.race_id,
        p_results: body.results,
        p_source_version: body.source_version || 'manual-v1',
        p_corrected_by: user.id,
      });
    case 'correct_results':
      return rpc('n26_correct_race_results', {
        p_race_id: body.race_id,
        p_results: body.results,
        p_source_version: body.source_version || 'manual-correction-v1',
        p_corrected_by: user.id,
      });
    case 'publish_race':
      return rpc('n26_publish_race_results', { p_race_id: body.race_id, p_appeal_hours: body.appeal_hours === undefined ? 48 : Number(body.appeal_hours) });
    case 'finalize_race':
    case 'certify_race':
      return rpc('n26_finalize_race', { p_race_id: body.race_id });
    case 'calculate_ratings':
      return calculateRatings(body.season_id);
    case 'certify_ratings': {
      const bundle = await getSeasonBundle(body.season_id);
      const fullTimeEntries = bundle.entries.filter(entry => entry.entry_status === 'full_time');
      const certifiedRaces = bundle.races.filter(race => ['completed', 'voided'].includes(race.status) && race.certification_status === 'certified');
      if (fullTimeEntries.length !== bundle.ruleset.driver_count) throw new Error(`Ratings require ${bundle.ruleset.driver_count} full-time entries.`);
      if (certifiedRaces.length !== bundle.ruleset.season_length) throw new Error('Ratings can only be certified after every scheduled race is certified.');
      await calculateRatings(bundle.season.id);
      return rpc('n26_certify_ratings', { p_season_id: bundle.season.id });
    }
    case 'certify_season': {
      return rpc('n26_certify_season', { p_season_id: body.season_id });
    }
    case 'prepare_next_season': {
      const bundle = await getSeasonBundle(body.previous_season_id || body.season_id);
      if (!['certified', 'archived'].includes(bundle.season.status)) {
        throw new Error('The previous season must be certified before preparing the next draft.');
      }
      const fullTimeEntries = bundle.entries.filter(entry => entry.entry_status === 'full_time');
      const certifiedSnapshots = await supabaseRequest(`/rest/v1/n26_rating_snapshots?season_id=eq.${bundle.season.id}&certification_status=eq.certified&select=driver_id,official_ovr`);
      if (certifiedSnapshots.length !== fullTimeEntries.length || !certifiedSnapshots.length) {
        throw new Error('Every full-time driver needs a certified OVR before the next season can be prepared.');
      }
      const ratings = fullTimeEntries.map(entry => {
        const snapshot = certifiedSnapshots.find(candidate => candidate.driver_id === entry.driver_id);
        if (!snapshot) throw new Error('A full-time entry is missing its certified OVR.');
        return Number(snapshot.official_ovr);
      });
      const minimum = rules.calculateMinimumFeasibleCap(ratings, bundle.ruleset.team_size);
      const capCredits = rules.calculateEqualLeagueCap(minimum.minimumMax);
      const seasonNumber = bundle.season.season_number + 1;
      const name = String(body.name || `Season ${seasonNumber}`).trim();
      const version = String(body.version || `${bundle.ruleset.version}-s${seasonNumber}`).trim();
      const created = await rpc('n26_create_draft_season', {
        p_previous_season_id: bundle.season.id,
        p_name: name,
        p_ruleset_version: version,
        p_cap_credits: capCredits,
      });
      return { season: Array.isArray(created) ? created[0] : created, minimum_max: minimum.minimumMax, cap_credits: capCredits };
    }
    case 'create_contract': {
      const bundle = await getSeasonBundle(body.season_id);
      const season = bundle.season;
      const term = Number(body.original_term_seasons);
      const termDiscount = Number(body.term_discount_bps || 0);
      const loyaltyDiscount = Number(body.loyalty_discount_bps || 0);
      if (!Number.isInteger(term) || term < 1 || term > 3) throw new Error('Contract term must be 1, 2, or 3 seasons.');
      let rating = 60;
      if (season.season_number > 1) {
        const previousSeasons = await supabaseRequest(`/rest/v1/n26_seasons?season_number=eq.${season.season_number - 1}&select=id&limit=1`);
        if (previousSeasons[0]) {
          const snapshots = await supabaseRequest(`/rest/v1/n26_rating_snapshots?season_id=eq.${previousSeasons[0].id}&driver_id=eq.${encodeURIComponent(body.driver_id)}&certification_status=eq.certified&select=official_ovr&limit=1`);
          if (snapshots[0]) rating = Number(snapshots[0].official_ovr);
        }
      }
      const assignment = bundle.assignments.find(candidate => candidate.driver_id === body.driver_id && candidate.team_id === body.team_id && candidate.assignment_status === 'active');
      if (!assignment) throw new Error('The driver must have an active seat with the destination team before signing.');
      const created = await rpc('n26_create_contract', {
        p_season_id: season.id,
        p_driver_id: body.driver_id,
        p_team_id: body.team_id,
        p_seat_assignment_id: assignment.id,
        p_rating: rating,
        p_original_term_seasons: term,
        p_term_discount_bps: termDiscount,
        p_loyalty_discount_bps: loyaltyDiscount,
      });
      return Array.isArray(created) ? created[0] : created;
    }
    case 'create_news_article': {
      if (!body.headline || String(body.headline).trim().length < 3) throw new Error('A headline is required.');
      const rows = await supabaseRequest('/rest/v1/n26_news_articles', {
        method: 'POST',
        headers: { Prefer: 'return=representation' },
        body: JSON.stringify({
          season_id: body.season_id || null,
          race_id: body.race_id || null,
          headline: String(body.headline).trim(),
          dek: String(body.dek || '').trim(),
          body: String(body.article_body || ''),
          image_url: body.image_url ? String(body.image_url).trim() : null,
          status: body.status === 'published' ? 'published' : 'draft',
          published_at: body.status === 'published' ? new Date().toISOString() : null,
          created_by: user.id,
        }),
      });
      return rows[0];
    }
    case 'update_news_article': {
      if (!body.id) throw new Error('An article is required.');
      const updates = {};
      for (const key of ['headline', 'dek']) if (body[key] !== undefined) updates[key] = String(body[key]);
      if (body.article_body !== undefined) updates.body = String(body.article_body);
      if (body.status !== undefined) updates.status = ['draft', 'published', 'archived'].includes(body.status) ? body.status : 'draft';
      if (updates.status === 'published') updates.published_at = new Date().toISOString();
      updates.updated_at = new Date().toISOString();
      const rows = await supabaseRequest(`/rest/v1/n26_news_articles?id=eq.${encodeURIComponent(body.id)}`, { method: 'PATCH', headers: { Prefer: 'return=representation' }, body: JSON.stringify(updates) });
      if (!rows.length) throw Object.assign(new Error('Article not found.'), { status: 404 });
      return rows[0];
    }
    case 'extend_contract': {
      const term = Number(body.additional_term_seasons);
      if (!body.season_id || !body.contract_id || !Number.isInteger(term)) {
        throw new Error('A season, current contract, and additional term are required.');
      }
      return rpc('n26_extend_contract', {
        p_season_id: body.season_id,
        p_contract_id: body.contract_id,
        p_additional_term_seasons: term,
      });
    }
    case 'release_contract':
      return rpc('n26_release_contract_for_season', {
        p_season_id: body.season_id,
        p_contract_id: body.contract_id,
        p_reason: body.reason ? String(body.reason).trim() : null,
      });
    case 'expire_contracts':
      return rpc('n26_expire_contracts', { p_season_id: body.season_id });
    case 'open_contract_market':
      return rpc('n26_open_contract_market', {
        p_season_id: body.season_id,
        p_renewal_hours: 48,
        p_free_agency_days: 5,
      });
    case 'publish_season': {
      return rpc('n26_publish_season', { p_season_id: body.season_id });
    }
    default:
      throw Object.assign(new Error(`Unknown action: ${action}`), { status: 400 });
  }
}

export default async function handler(req, res) {
  if (req.method === 'OPTIONS') return res.status(204).end();
  if (req.method !== 'POST') return json(res, 405, { error: 'Method not allowed' });
  try {
    const user = await requireAdmin(req);
    const body = req.body || {};
    const result = await handleAction(body.action, body, user);
    return json(res, 200, { ok: true, result });
  } catch (error) {
    console.error('League admin error:', error);
    return json(res, error.status || 500, { ok: false, error: error.message || 'Internal error' });
  }
}
