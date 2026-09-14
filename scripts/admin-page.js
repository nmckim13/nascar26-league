import { requireUser } from './supabase-auth.js';

const state = { auth: null, bundle: null };

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>'"]/g, character => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;',
  }[character]));
}

function setMessage(id, text, error = false) {
  const element = document.getElementById(id);
  element.textContent = text || '';
  element.classList.toggle('error', error);
}

async function call(action, payload = {}) {
  const response = await fetch('/api/league-admin', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${state.auth.session.access_token}`,
    },
    body: JSON.stringify({ action, ...payload }),
  });
  const body = await response.json().catch(() => ({}));
  if (!response.ok || !body.ok) throw new Error(body.error || 'Commissioner request failed.');
  return body.result;
}

function render(bundle) {
  state.bundle = bundle;
  const active = bundle.assignments.filter(assignment => assignment.assignment_status === 'active');
  const fullTime = bundle.entries.filter(entry => entry.entry_status === 'full_time');
  const pendingApplications = (bundle.applications || []).filter(application => application.approval_status === 'pending');
  document.getElementById('stats').innerHTML = [
    ['Drivers', bundle.drivers.length],
    ['Awaiting approval', pendingApplications.length],
    ['Full-time / target', `${fullTime.length} / 24`],
    ['Active seats', active.length],
    ['Races', bundle.races.length],
    ['Points schedule', bundle.ruleset.config?.points_schedule_status === 'approved' ? 'Approved' : 'Pending'],
  ].map(([label, value]) => `<div class="stat"><strong>${value}</strong><span>${label}</span></div>`).join('');

  const teams = Object.fromEntries(bundle.teams?.map(team => [team.id, team.name]) || []);
  const drivers = Object.fromEntries(bundle.drivers.map(driver => [driver.id, driver]));
  const activeAssignments = Object.fromEntries(active.map(assignment => [assignment.driver_id, assignment]));
  document.getElementById('roster').innerHTML = bundle.entries.map(entry => {
    const driver = drivers[entry.driver_id] || {};
    const assignment = activeAssignments[entry.driver_id];
    return `<tr><td>${escapeHtml(driver.display_name || 'Unknown')}</td><td>${escapeHtml(driver.gamertag || '—')}</td><td>${escapeHtml(entry.entry_status)}</td><td>${escapeHtml(assignment ? (teams[assignment.team_id] || assignment.team_id) : 'Unassigned')}</td><td>${assignment ? `#${escapeHtml(assignment.car_number)}` : '—'}</td></tr>`;
  }).join('');

  document.getElementById('applications').innerHTML = pendingApplications.length
    ? pendingApplications.map(application => {
      const name = [application.first_name, application.last_name].filter(Boolean).join(' ').trim() || application.gamertag || 'Unknown';
      return `<tr>
        <td>${escapeHtml(name)}</td>
        <td>${escapeHtml(application.gamertag || '—')}</td>
        <td>#${escapeHtml(application.car_number)} · ${escapeHtml(application.team_name)}</td>
        <td>${escapeHtml(application.discord_username || '—')}</td>
        <td>${escapeHtml(new Date(application.claimed_at).toLocaleDateString())}</td>
        <td><div style="display:flex;gap:6px;min-width:170px"><button type="button" data-application-action="approve_application" data-application-id="${escapeHtml(application.id)}" style="width:auto;padding:8px 10px">Approve</button><button type="button" class="secondary" data-application-action="reject_application" data-application-id="${escapeHtml(application.id)}" style="width:auto;padding:8px 10px">Decline</button></div></td>
      </tr>`;
    }).join('')
    : '<tr><td colspan="6" class="muted">No applications are waiting for approval.</td></tr>';

  const driverOptions = bundle.drivers.map(driver => `<option value="${escapeHtml(driver.id)}">${escapeHtml(driver.display_name)}${driver.gamertag ? ` (${escapeHtml(driver.gamertag)})` : ''}</option>`).join('');
  document.getElementById('seatDriver').innerHTML = driverOptions;
  document.getElementById('releaseDriver').innerHTML = driverOptions;
  document.getElementById('contractDriver').innerHTML = driverOptions;
  document.getElementById('departingDriver').innerHTML = driverOptions;
  document.getElementById('replacementDriver').innerHTML = driverOptions;
  document.getElementById('loginDriver').innerHTML = driverOptions;
  document.getElementById('seatTeam').innerHTML = bundle.teams.map(team => `<option value="${escapeHtml(team.id)}">${escapeHtml(team.name)}</option>`).join('');
  document.getElementById('contractTeam').innerHTML = bundle.teams.map(team => `<option value="${escapeHtml(team.id)}">${escapeHtml(team.name)}</option>`).join('');
  document.getElementById('profileTeam').innerHTML = bundle.teams.map(team => `<option value="${escapeHtml(team.id)}">${escapeHtml(team.name)}</option>`).join('');
  document.getElementById('raceSelect').innerHTML = bundle.races.map(race => `<option value="${escapeHtml(race.id)}">Race ${escapeHtml(race.race_number)} · ${escapeHtml(race.track_short)}</option>`).join('');
  document.getElementById('contracts').innerHTML = (bundle.contracts || []).length
    ? bundle.contracts.map(contract => {
      const driver = drivers[contract.driver_id] || {};
      return `<tr><td>${escapeHtml(driver.display_name || 'Unknown')}</td><td>${escapeHtml(teams[contract.team_id] || contract.team_id)}</td><td>${escapeHtml(contract.original_term_seasons)} season(s)</td><td>${(Number(contract.cap_charge_cents || 0) / 100).toFixed(2)}</td><td>${escapeHtml(contract.status)}</td></tr>`;
    }).join('')
    : '<tr><td colspan="5" class="muted">No contracts recorded.</td></tr>';
  const currentContracts = (bundle.contracts || []).filter(contract => ['introductory', 'active'].includes(contract.status));
  document.getElementById('contractReleaseSelect').innerHTML = currentContracts.length
    ? currentContracts.map(contract => {
      const driver = drivers[contract.driver_id] || {};
      return `<option value="${escapeHtml(contract.id)}">${escapeHtml(driver.display_name || 'Unknown')} · ${escapeHtml(teams[contract.team_id] || contract.team_id)} · ${Number(contract.cap_charge_cents || 0) / 100} credits</option>`;
    }).join('')
    : '<option value="">No current contracts</option>';
  document.getElementById('contractReleaseSelect').disabled = !currentContracts.length;
  document.getElementById('extendContractSelect').innerHTML = currentContracts.length
    ? currentContracts.map(contract => {
      const driver = drivers[contract.driver_id] || {};
      return `<option value="${escapeHtml(contract.id)}">${escapeHtml(driver.display_name || 'Unknown')} · ${escapeHtml(teams[contract.team_id] || contract.team_id)} · through Season ${escapeHtml(contract.end_season)}</option>`;
    }).join('')
    : '<option value="">No current contracts</option>';
  document.getElementById('extendContractSelect').disabled = !currentContracts.length;
  updateTeamProfileForm();
  updateCarOptions();
  updateRaceSetup();
}

function updateTeamProfileForm() {
  const team = state.bundle?.teams.find(candidate => candidate.id === document.getElementById('profileTeam').value);
  if (!team) return;
  document.getElementById('profileOwner').value = team.owner_name || '';
  document.getElementById('profileHonors').value = JSON.stringify(team.honors || [], null, 2);
}

function updateCarOptions() {
  const teamId = document.getElementById('seatTeam').value;
  const driverId = document.getElementById('seatDriver').value;
  const occupiedByOtherDriver = new Set((state.bundle?.assignments || [])
    .filter(assignment => assignment.assignment_status === 'active' && assignment.driver_id !== driverId)
    .map(assignment => `${assignment.team_id}:${assignment.car_number}`));
  const cars = (state.bundle?.catalog || []).filter(car => (
    car.team_id === teamId && !occupiedByOtherDriver.has(`${car.team_id}:${car.car_number}`)
  ));
  document.getElementById('seatCar').innerHTML = cars.map(car => `<option value="${escapeHtml(car.car_number)}">#${escapeHtml(car.car_number)}</option>`).join('');
}

function updateRaceSetup() {
  const race = state.bundle?.races.find(candidate => candidate.id === document.getElementById('raceSelect').value);
  if (!race) return;
  document.getElementById('startersCount').value = race.starters_count ?? '';
  document.getElementById('qualifyingCount').value = race.qualifying_field_count ?? '';
  document.getElementById('qualifyingStatus').value = race.qualifying_status || 'not_recorded';
}

async function refresh() {
  setMessage('overviewMessage', 'Loading commissioner data...');
  try {
    const bundle = await call('overview');
    render(bundle);
    setMessage('overviewMessage', `Season ${bundle.season.season_number} is ${bundle.season.status}.`);
  } catch (error) {
    setMessage('overviewMessage', error.message, true);
  }
}

async function runAction(action) {
  setMessage('actionMessage', 'Working...');
  try {
    const result = await call(action, { season_id: state.bundle?.season.id });
    setMessage('actionMessage', action === 'calculate_ratings' ? `${result.snapshots.length} provisional ratings calculated.` : 'Action completed.');
    await refresh();
  } catch (error) {
    setMessage('actionMessage', error.message, true);
  }
}

async function init() {
  state.auth = await requireUser('admin.html');
  if (!state.auth) return;
  document.getElementById('applications').addEventListener('click', async event => {
    const button = event.target.closest('[data-application-action]');
    if (!button) return;
    const action = button.dataset.applicationAction;
    const applicationId = button.dataset.applicationId;
    button.disabled = true;
    setMessage('applicationMessage', action === 'approve_application' ? 'Approving applicant and assigning the requested seat...' : 'Declining application...');
    try {
      await call(action, { application_id: applicationId, season_id: state.bundle?.season.id });
      setMessage('applicationMessage', action === 'approve_application' ? 'Applicant approved and added to the league.' : 'Application declined. The car is available again.');
      await refresh();
    } catch (error) {
      button.disabled = false;
      setMessage('applicationMessage', error.message, true);
    }
  });
  document.getElementById('driverForm').addEventListener('submit', async event => {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    setMessage('actionMessage', 'Adding driver...');
    try {
      await call('create_driver', { ...Object.fromEntries(form.entries()), season_id: state.bundle?.season.id });
      event.currentTarget.reset();
      setMessage('actionMessage', 'Permanent driver identity added.');
      await refresh();
    } catch (error) { setMessage('actionMessage', error.message, true); }
  });
  document.getElementById('linkLoginForm').addEventListener('submit', async event => {
    event.preventDefault();
    setMessage('actionMessage', 'Linking driver login...');
    try {
      const values = Object.fromEntries(new FormData(event.currentTarget).entries());
      await call('link_driver_account', values);
      event.currentTarget.reset();
      setMessage('actionMessage', 'Driver login linked. Their portal is ready.');
      await refresh();
    } catch (error) { setMessage('actionMessage', error.message, true); }
  });
  document.getElementById('importRoster').addEventListener('click', async () => {
    try {
      const roster = JSON.parse(document.getElementById('rosterJson').value);
      if (!Array.isArray(roster) || !roster.length) throw new Error('Paste a non-empty JSON array of new drivers.');
      setMessage('actionMessage', `Importing ${roster.length} roster rows...`);
      const result = await call('import_roster', { season_id: state.bundle.season.id, roster });
      setMessage('actionMessage', `${result.created_drivers} identities created and ${result.assigned_seats} seats assigned atomically.`);
      document.getElementById('rosterJson').value = '';
      await refresh();
    } catch (error) { setMessage('actionMessage', error.message, true); }
  });
  document.getElementById('syncClaims').addEventListener('click', async () => {
    try {
      setMessage('actionMessage', 'Syncing authenticated claims into the draft...');
      const result = await call('sync_claims', { season_id: state.bundle.season.id });
      setMessage('actionMessage', `${result.created_drivers} identities created and ${result.assigned_seats} draft seats assigned from claims.`);
      await refresh();
    } catch (error) { setMessage('actionMessage', error.message, true); }
  });
  document.getElementById('calculateRatings').addEventListener('click', () => runAction('calculate_ratings'));
  document.getElementById('certifyRatings').addEventListener('click', () => runAction('certify_ratings'));
  document.getElementById('certifySeason').addEventListener('click', () => runAction('certify_season'));
  document.getElementById('prepareNextSeason').addEventListener('click', async () => {
    const number = Number(state.bundle?.season.season_number || 1) + 1;
    const name = window.prompt('Name for the next season:', `Season ${number}`);
    if (name === null) return;
    const version = window.prompt('Immutable ruleset version:', `${state.bundle?.ruleset.version || '2.0'}-s${number}`);
    if (version === null) return;
    try {
      const result = await call('prepare_next_season', { previous_season_id: state.bundle.season.id, name, version });
      setMessage('actionMessage', `Season ${number} draft created with a ${result.cap_credits}-credit cap (minimum feasible max ${result.minimum_max}).`);
    } catch (error) { setMessage('actionMessage', error.message, true); }
  });
  document.getElementById('publishSeason').addEventListener('click', () => runAction('publish_season'));
  document.getElementById('approvePoints').addEventListener('click', async () => {
    try {
      const points = JSON.parse(document.getElementById('pointsJson').value);
      const version = document.getElementById('pointsVersion').value.trim();
      if (!version) throw new Error('A ruleset version is required.');
      const scheduleErrors = window.N26LeagueRules.validatePointsSchedule(points, 24);
      if (scheduleErrors.length) throw new Error(scheduleErrors.join(' '));
      const result = await call('approve_points_schedule', { season_id: state.bundle.season.id, version, points_by_position: points });
      setMessage('actionMessage', `Approved ${result.version}; the draft season now uses the complete 24-position schedule.`);
      await refresh();
    } catch (error) { setMessage('actionMessage', error.message, true); }
  });
  document.getElementById('newsForm').addEventListener('submit', async event => {
    event.preventDefault();
    try {
      const values = Object.fromEntries(new FormData(event.currentTarget).entries());
      await call('create_news_article', { ...values, season_id: state.bundle.season.id });
      event.currentTarget.reset();
      setMessage('actionMessage', 'News article created.');
    } catch (error) { setMessage('actionMessage', error.message, true); }
  });
  document.getElementById('seatTeam').addEventListener('change', updateCarOptions);
  document.getElementById('seatDriver').addEventListener('change', updateCarOptions);
  document.getElementById('profileTeam').addEventListener('change', updateTeamProfileForm);
  document.getElementById('teamProfileForm').addEventListener('submit', async event => {
    event.preventDefault();
    try {
      const form = new FormData(event.currentTarget);
      await call('update_team_profile', {
        team_id: form.get('team_id'),
        owner_name: form.get('owner_name'),
        honors: JSON.parse(form.get('honors') || '[]'),
      });
      setMessage('actionMessage', 'Team profile saved.');
      await refresh();
    } catch (error) { setMessage('actionMessage', error.message, true); }
  });
  document.getElementById('replacementForm').addEventListener('submit', async event => {
    event.preventDefault();
    try {
      const values = Object.fromEntries(new FormData(event.currentTarget).entries());
      await call('replace_driver_midseason', { ...values, season_id: state.bundle.season.id });
      event.currentTarget.reset();
      setMessage('actionMessage', 'Midseason replacement recorded; both identities and transactions were preserved.');
      await refresh();
    } catch (error) { setMessage('actionMessage', error.message, true); }
  });
  document.getElementById('seatForm').addEventListener('submit', async event => {
    event.preventDefault();
    try {
      const values = Object.fromEntries(new FormData(event.currentTarget).entries());
      await call('assign_seat', {
        ...values,
        season_id: state.bundle.season.id,
        allow_transfer: values.allow_transfer === 'on',
        driver_consented: values.driver_consented === 'on',
        from_team_consented: values.from_team_consented === 'on',
        to_team_consented: values.to_team_consented === 'on',
      });
      setMessage('actionMessage', 'Seat assignment saved and transaction logged.');
      await refresh();
    } catch (error) { setMessage('actionMessage', error.message, true); }
  });
  document.getElementById('releaseForm').addEventListener('submit', async event => {
    event.preventDefault();
    try {
      const values = Object.fromEntries(new FormData(event.currentTarget).entries());
      await call('release_seat', { ...values, season_id: state.bundle.season.id });
      setMessage('actionMessage', 'Seat released and transaction logged.');
      await refresh();
    } catch (error) { setMessage('actionMessage', error.message, true); }
  });
  document.getElementById('contractForm').addEventListener('submit', async event => {
    event.preventDefault();
    try {
      const values = Object.fromEntries(new FormData(event.currentTarget).entries());
      await call('create_contract', { ...values, season_id: state.bundle.season.id });
      event.currentTarget.reset();
      setMessage('actionMessage', 'Contract created and cap charge recorded.');
      await refresh();
    } catch (error) { setMessage('actionMessage', error.message, true); }
  });
  document.getElementById('releaseContractForm').addEventListener('submit', async event => {
    event.preventDefault();
    try {
      const values = Object.fromEntries(new FormData(event.currentTarget).entries());
      await call('release_contract', values);
      event.currentTarget.reset();
      setMessage('actionMessage', 'Contract released and transaction logged. The seat remains a separate roster action.');
      await refresh();
    } catch (error) { setMessage('actionMessage', error.message, true); }
  });
  document.getElementById('expireContracts').addEventListener('click', async () => {
    try {
      const result = await call('expire_contracts', { season_id: state.bundle.season.id });
      setMessage('actionMessage', `${result.expired_contracts} contract(s) expired and logged.`);
      await refresh();
    } catch (error) { setMessage('actionMessage', error.message, true); }
  });
  document.getElementById('openContractMarket').addEventListener('click', async () => {
    try {
      const result = await call('open_contract_market', { season_id: state.bundle.season.id });
      setMessage('actionMessage', `Renewals open until ${new Date(result.renewal_window_ends_at).toLocaleString()}; free agency closes ${new Date(result.free_agency_closes_at).toLocaleString()}.`);
      await refresh();
    } catch (error) { setMessage('actionMessage', error.message, true); }
  });
  document.getElementById('extendContractForm').addEventListener('submit', async event => {
    event.preventDefault();
    try {
      const values = Object.fromEntries(new FormData(event.currentTarget).entries());
      await call('extend_contract', { ...values, season_id: state.bundle.season.id });
      event.currentTarget.reset();
      setMessage('actionMessage', 'Incumbent contract extension recorded as a renewal.');
      await refresh();
    } catch (error) { setMessage('actionMessage', error.message, true); }
  });
  document.getElementById('openRace').addEventListener('click', () => runRaceAction('open_race'));
  document.getElementById('publishRace').addEventListener('click', () => runRaceAction('publish_race'));
  document.getElementById('finalizeRace').addEventListener('click', () => runRaceAction('finalize_race'));
  document.getElementById('voidRace').addEventListener('click', async () => {
    const reason = window.prompt('Why is this race being voided?');
    if (reason === null) return;
    try {
      await call('void_race', { race_id: document.getElementById('raceSelect').value, reason });
      setMessage('actionMessage', 'Race voided and excluded from championship totals.');
      await refresh();
    } catch (error) { setMessage('actionMessage', error.message, true); }
  });
  document.getElementById('raceSelect').addEventListener('change', updateRaceSetup);
  document.getElementById('saveRaceSetup').addEventListener('click', async () => {
    try {
      const startersCount = Number(document.getElementById('startersCount').value);
      const qualifyingCount = Number(document.getElementById('qualifyingCount').value);
      if (!Number.isInteger(startersCount) || startersCount < 1 || !Number.isInteger(qualifyingCount) || qualifyingCount < 0) {
        throw new Error('Starter and qualifying field counts must be whole numbers.');
      }
      await call('configure_race', {
        race_id: document.getElementById('raceSelect').value,
        starters_count: startersCount,
        qualifying_field_count: qualifyingCount,
        qualifying_status: document.getElementById('qualifyingStatus').value,
      });
      setMessage('actionMessage', 'Race setup saved.');
      await refresh();
    } catch (error) { setMessage('actionMessage', error.message, true); }
  });
  document.getElementById('recordResults').addEventListener('click', async () => {
    try {
      const results = JSON.parse(document.getElementById('resultJson').value);
      await call('record_results', { race_id: document.getElementById('raceSelect').value, results });
      setMessage('actionMessage', `${results.length} draft result rows saved.`);
    } catch (error) { setMessage('actionMessage', error.message, true); }
  });
  document.getElementById('correctResults').addEventListener('click', async () => {
    try {
      const results = JSON.parse(document.getElementById('resultJson').value);
      await call('correct_results', { race_id: document.getElementById('raceSelect').value, results });
      setMessage('actionMessage', `${results.length} correction rows saved and republished for appeal review.`);
    } catch (error) { setMessage('actionMessage', error.message, true); }
  });
  await refresh();
}

async function runRaceAction(action) {
  try {
    await call(action, { race_id: document.getElementById('raceSelect').value });
    setMessage('actionMessage', 'Race action completed.');
    await refresh();
  } catch (error) { setMessage('actionMessage', error.message, true); }
}

init().catch(error => setMessage('overviewMessage', error.message, true));
