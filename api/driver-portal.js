import { NUMBER_STYLES } from '../data/driver-number-styles.js';

const SUPABASE_URL = process.env.SUPABASE_URL;
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

function send(res, status, body) { return res.status(status).json(body); }

async function request(path, options = {}) {
  const response = await fetch(`${SUPABASE_URL}${path}`, {
    ...options,
    headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, 'Content-Type': 'application/json', ...(options.headers || {}) },
  });
  const body = await response.json().catch(() => null);
  if (!response.ok) throw Object.assign(new Error(body?.message || 'League data request failed.'), { status: response.status });
  return body;
}

async function currentUser(req) {
  if (!SUPABASE_URL || !SERVICE_KEY) throw Object.assign(new Error('Portal configuration is incomplete.'), { status: 503 });
  const authorization = req.headers.authorization || '';
  if (!authorization.startsWith('Bearer ')) throw Object.assign(new Error('Sign-in required.'), { status: 401 });
  const response = await fetch(`${SUPABASE_URL}/auth/v1/user`, { headers: { apikey: SERVICE_KEY, Authorization: authorization } });
  if (!response.ok) throw Object.assign(new Error('Your session has expired. Please sign in again.'), { status: 401 });
  return response.json();
}

async function isCommissioner(token) {
  const response = await fetch(`${SUPABASE_URL}/rest/v1/rpc/is_admin`, {
    method: 'POST', headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: '{}',
  });
  return response.ok && (await response.json()) === true;
}

async function loadPortal(user, token) {
  const [driverRows, seasonRows, commissioner] = await Promise.all([
    request(`/rest/v1/n26_drivers?auth_user_id=eq.${user.id}&select=id,display_name,gamertag,first_name,last_name,status&limit=1`),
    request('/rest/v1/n26_seasons?select=id,season_number,name,status&order=season_number.desc&limit=1'),
    isCommissioner(token),
  ]);
  const driver = driverRows[0] || null;
  const season = seasonRows[0] || null;
  if (!driver || !season) return { user: { email: user.email }, driver, season, commissioner, assignment: null, team: null, teammates: [], contract: null };

  const assignments = await request(`/rest/v1/n26_seat_assignments?season_id=eq.${season.id}&assignment_status=eq.active&select=id,driver_id,team_id,car_number,starts_at`);
  const assignment = assignments.find(row => row.driver_id === driver.id) || null;
  if (!assignment) return { user: { email: user.email }, driver, season, commissioner, assignment, team: null, teammates: [], contract: null };
  const teamAssignments = assignments.filter(row => row.team_id === assignment.team_id);
  const teammateIds = teamAssignments.map(row => row.driver_id);
  const [teamRows, teammateRows, contractRows, numberStyleRows] = await Promise.all([
    request(`/rest/v1/n26_teams?id=eq.${assignment.team_id}&select=id,name,slug,owner_name,seat_limit`),
    request(`/rest/v1/n26_drivers?id=in.(${teammateIds.join(',')})&select=id,display_name,gamertag`),
    request(`/rest/v1/n26_contracts?driver_id=eq.${driver.id}&season_id=eq.${season.id}&status=in.(introductory,active)&select=id,status,start_season,end_season,original_term_seasons,cap_charge_cents&order=created_at.desc&limit=1`),
    request(`/rest/v1/n26_driver_number_styles?driver_id=eq.${driver.id}&car_number=eq.${assignment.car_number}&select=style_key&limit=1`),
  ]);
  const names = Object.fromEntries(teammateRows.map(row => [row.id, row]));
  const teammates = teamAssignments.filter(row => row.driver_id !== driver.id).map(row => ({
    car_number: row.car_number,
    display_name: names[row.driver_id]?.display_name || names[row.driver_id]?.gamertag || 'Driver pending',
  })).sort((a, b) => Number(a.car_number) - Number(b.car_number));
  const contract = contractRows[0] || (Number(season.season_number) === 1 ? {
    status: 'introductory', start_season: 1, end_season: 1,
    original_term_seasons: 1, cap_charge_cents: 5000,
  } : null);
  return { user: { email: user.email }, driver, season, commissioner, assignment, team: teamRows[0] || null, teammates, contract, numberStyleKey: numberStyleRows[0]?.style_key || null };
}

export default async function handler(req, res) {
  if (!['GET', 'PATCH'].includes(req.method)) return send(res, 405, { ok: false, error: 'Method not allowed.' });
  try {
    const user = await currentUser(req);
    const token = req.headers.authorization.slice(7).trim();
    if (req.method === 'PATCH') {
      const driverRows = await request(`/rest/v1/n26_drivers?auth_user_id=eq.${user.id}&select=id&limit=1`);
      if (!driverRows.length) return send(res, 404, { ok: false, error: 'No approved driver profile is linked to this account yet.' });
      const clean = value => value == null ? null : String(value).trim();
      if (Object.hasOwn(req.body || {}, 'display_name')) {
        const update = {
          display_name: clean(req.body?.display_name), gamertag: clean(req.body?.gamertag),
          first_name: clean(req.body?.first_name), last_name: clean(req.body?.last_name),
        };
        if (!update.display_name || update.display_name.length < 2 || update.display_name.length > 80) {
          return send(res, 400, { ok: false, error: 'Display name must be between 2 and 80 characters.' });
        }
        await request(`/rest/v1/n26_drivers?id=eq.${driverRows[0].id}`, { method: 'PATCH', headers: { Prefer: 'return=minimal' }, body: JSON.stringify(update) });
      }
      if (Object.hasOwn(req.body || {}, 'number_style_key')) {
        const assignments = await request(`/rest/v1/n26_seat_assignments?driver_id=eq.${driverRows[0].id}&assignment_status=eq.active&select=car_number&order=starts_at.desc&limit=1`);
        const carNumber = String(assignments[0]?.car_number || '');
        const styleKey = clean(req.body.number_style_key);
        if (!carNumber) return send(res, 409, { ok: false, error: 'An active car assignment is required before selecting number artwork.' });
        if (!(NUMBER_STYLES[carNumber] || []).some(style => style.key === styleKey)) return send(res, 400, { ok: false, error: 'That number style is not available for your current car.' });
        await request('/rest/v1/n26_driver_number_styles?on_conflict=driver_id,car_number', {
          method: 'POST', headers: { Prefer: 'resolution=merge-duplicates,return=minimal' },
          body: JSON.stringify({ driver_id: driverRows[0].id, car_number: carNumber, style_key: styleKey, updated_at: new Date().toISOString() }),
        });
      }
    }
    return send(res, 200, { ok: true, result: await loadPortal(user, token) });
  } catch (error) {
    return send(res, error.status || 500, { ok: false, error: error.message || 'Driver portal request failed.' });
  }
}
