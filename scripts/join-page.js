// Recruitment is public. Login is an explicit action for existing drivers only.
document.querySelectorAll('.site-header .nav-cta, .site-header .drawer-cta').forEach(link => {
  link.href = 'auth.html';
  link.textContent = 'Driver login →';
});

const interestForm = document.getElementById('interest-form');
interestForm.addEventListener('submit', async event => {
  event.preventDefault();
  if (interestForm.getAttribute('aria-busy') === 'true') return;
  const fields = new FormData(interestForm);
  const button = interestForm.querySelector('button[type="submit"]');
  const message = document.getElementById('interest-error');
  message.textContent = '';
  button.disabled = true;
  button.textContent = 'Saving your interest…';
  interestForm.setAttribute('aria-busy', 'true');
  try {
    const response = await fetch('/api/season-interest', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email: fields.get('email'), platform: fields.get('platform'), website: fields.get('website') }),
      signal: AbortSignal.timeout(15000),
    });
    const body = await response.json().catch(() => ({}));
    if (!response.ok || body.ok !== true) {
      throw new Error(response.status === 429
        ? 'Too many attempts. Please wait 10 minutes and try again.'
        : response.status === 400
          ? 'Check your email and choose PlayStation, Xbox, or PC.'
          : 'The interest list is temporarily unavailable. Please try again shortly.');
    }
    interestForm.reset();
    interestForm.hidden = true;
    const confirmation = document.getElementById('interest-confirmation');
    confirmation.hidden = false;
    confirmation.focus();
  } catch (error) {
    message.textContent = error.name === 'TimeoutError' || error.name === 'TypeError'
      ? 'We could not confirm your submission. Check your connection and try again; repeat submissions will not create duplicate entries.'
      : error.message;
  } finally {
    interestForm.removeAttribute('aria-busy');
    button.disabled = false;
    button.textContent = 'Join the interest list →';
  }
});

async function loadRecruitmentSummary() {
  const data = await window.__leagueDataReady;
  if (!data) throw new Error('Public season data is unavailable.');
  const races = [...(data.races || [])].sort((a, b) => a.race_number - b.race_number);
  const results = data.results || [];
  const claims = data.claims || [];
  const driverName = (driverId, carNumber) => {
    const identity = claims.find(claim => driverId ? claim.driver_id === driverId : String(claim.car_number) === String(carNumber))
      || (data.drivers || []).find(driver => driver.id === driverId) || {};
    return identity.displayName || [identity.first_name, identity.last_name].filter(Boolean).join(' ').trim()
      || identity.display_name || identity.gamertag || `Car #${carNumber ?? '—'}`;
  };

  // Match index.html: published awards, season-specific championship format,
  // eligible starters, and the shared sporting tiebreaks.
  const standings = data.source === 'normalized' && data.ruleset
    ? window.N26LeagueRules.calculatePublicSeasonStandings({
      championshipFormat: data.ruleset.config?.championship_format,
      entries: (data.entries || []).map(entry => ({
        driverId: entry.driver_id,
        teamId: (data.assignments || []).find(assignment => assignment.driver_id === entry.driver_id)?.team_id || null,
        entryStatus: entry.entry_status,
      })),
      races,
      results,
      pointsByPosition: data.ruleset.points_by_position,
      strict: false,
    }) : null;
  const completedRaces = standings?.completedRaces || races.filter(race => race.status === 'completed');
  const completedIds = new Set(completedRaces.map(race => race.id));
  const seasonName = data.season?.name || `Season ${data.season?.season_number || 1}`;
  document.getElementById('recruit-season-label').textContent = `${seasonName} / Published championship`;

  const next = races.find(race => !['completed', 'voided'].includes(race.status));
  if (next) {
    document.getElementById('recruit-next').textContent = next.track_name || next.track_short;
    document.getElementById('recruit-next-detail').textContent = `Race ${next.race_number} · ${next.race_date || 'Date to be announced'}`;
    const scenes = {
      Daytona: 'daytona', Nashville: 'nashville', Bristol: 'bristol', 'Watkins Glen': 'watkins-glen',
      Charlotte: 'charlotte', Iowa: 'iowa', Talladega: 'talladega', Chicagoland: 'chicagoland',
      Dover: 'dover', Phoenix: 'phoenix', Rockingham: 'rockingham',
    };
    if (scenes[next.track_short]) document.querySelector('.recruit-next').style.setProperty('--recruit-race-scene', `url('assets/schedule/scenes/${scenes[next.track_short]}.jpg')`);
  } else if (races.length) {
    document.getElementById('recruit-next').textContent = 'No upcoming race';
    document.getElementById('recruit-next-detail').textContent = 'See the schedule for the completed season.';
  }

  const winnerForRace = race => results.find(result => result.race_id === race.id
    && result.start_status === 'started' && result.finish_status !== 'disqualified' && result.finish_position === 1);
  const last = [...completedRaces].reverse().find(winnerForRace);
  if (last) {
    const winner = winnerForRace(last);
    const name = driverName(winner.driver_id, winner.car_number);
    document.getElementById('recruit-winner').textContent = name;
    document.getElementById('recruit-winner-detail').textContent = `${last.track_short || last.track_name} · Race ${last.race_number} · #${winner.car_number}`;
    const truck = document.getElementById('recruit-winner-truck');
    const art = window.BARLCarArt?.[String(winner.car_number)];
    if (art?.vehicleImage) {
      truck.src = art.vehicleImage;
      truck.alt = `${name}'s number ${winner.car_number} BARL racing truck illustration`;
      truck.hidden = false;
    }
    window.dispatchEvent(new CustomEvent('barl:home-summary', { detail: { race: last, winnerName: name, number: winner.car_number } }));
  }

  let leaders;
  if (standings) {
    leaders = standings.drivers.map(driver => ({
      rank: driver.rank,
      name: driverName(driver.driverId, (data.assignments || []).find(assignment => assignment.driver_id === driver.driverId)?.car_number),
      points: driver.points,
    }));
  } else {
    // Retain the homepage's legacy display contract without inventing a ruleset.
    leaders = claims.map(claim => ({
      key: claim.car_number,
      name: driverName(claim.driver_id, claim.car_number),
      points: results.filter(result => completedIds.has(result.race_id) && String(result.car_number) === String(claim.car_number))
        .reduce((total, result) => total + (result.points_earned || 0), 0),
    })).sort((a, b) => b.points - a.points || String(a.key).localeCompare(String(b.key)))
      .map((driver, index) => ({ ...driver, rank: index + 1 }));
  }
  const list = document.getElementById('recruit-top-three');
  list.replaceChildren();
  if (completedRaces.length) {
    leaders.slice(0, 3).forEach(driver => {
      const row = document.createElement('li');
      [driver.rank, driver.name, `${driver.points} pts`].forEach(value => {
        const cell = document.createElement('span');
        cell.textContent = String(value);
        row.append(cell);
      });
      list.append(row);
    });
  }
  document.getElementById('recruit-points-note').textContent = completedRaces.length && leaders.length
    ? data.ruleset?.config?.championship_format === 'chase_12_7_3'
      ? `${standings.chaseActive ? 'Seeded Chase points + rounds 8–10' : 'All regular-season race points count'} · No dropped scores.`
      : standings ? `Best ${Math.max(0, completedRaces.length - 1)} of ${completedRaces.length} completed races count.` : 'Published season points.'
    : 'Standings appear after published race results.';
  document.getElementById('recruit-data-note').textContent = data.source === 'prelaunch'
    ? 'No published season summary is available yet. Follow the season home for updates.'
    : 'Live summary from published league records.';
}

loadRecruitmentSummary().catch(error => {
  console.error('Unable to load recruitment season summary', error);
  document.getElementById('recruit-data-note').textContent = 'Season summary is temporarily unavailable. Follow the season home for updates.';
});
