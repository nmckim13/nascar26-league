import {
  redirectToAuth,
  supabase,
} from './supabase-auth.js';
import { loadCurrentRosterSeason, loadNormalizedSeasonData, loadPublishedSeason, loadTeamCatalog, toLegacyDisplayData } from './league-public.js';

const FALLBACK_TEAM_MAP = {
  hms: ['5', '9', '24', '48'],
  jgr: ['11', '19', '20', '54'],
  penske: ['2', '12', '22'],
  '23xi': ['23', '35', '45'],
  rfk: ['6', '17', '60'],
  spire: ['7', '71', '77'],
  trackhouse: ['1', '88', '97'],
  lmc: ['42', '43', '84'],
};

const state = {
  claimedCars: [],
  existingClaim: null,
  selectedCard: null,
  user: null,
  claimingClosed: false,
  teamMap: { ...FALLBACK_TEAM_MAP },
};

async function renderCupCatalog() {
  const target = document.getElementById('cupCatalog');
  if (!target) return;
  try {
    const response = await fetch('./data/cup-number-catalog.json');
    if (!response.ok) throw new Error(`Catalog request failed (${response.status})`);
    const catalog = await response.json();
    target.replaceChildren(...catalog.numbers.map((entry) => {
      const card = document.createElement('div');
      card.className = 'catalog-card';
      const image = document.createElement('img');
      image.className = 'car-num-img';
      image.src = `https://cf.nascar.com/data/images/carbadges/1/${entry.number}.png`;
      image.alt = `Number ${entry.number}`;
      const copy = document.createElement('div');
      copy.innerHTML = `<div class="catalog-number">#${entry.number}</div><div class="catalog-meta"></div>`;
      copy.querySelector('.catalog-meta').textContent = `${entry.organization} | ${entry.manufacturer}`;
      card.append(image, copy);
      return card;
    }));
  } catch (error) {
    console.warn('Could not load Cup number catalog', error);
  }
}

function formatDriverName(claim) {
  return [claim.first_name, claim.last_name].filter(Boolean).join(' ').trim() || claim.gamertag;
}

function revealProtectedPage() {
  document.body.classList.remove('loading-auth');
}

function hideBanner() {
  document.getElementById('selBanner').classList.remove('visible');
}

function lockClaiming(season) {
  state.claimingClosed = true;
  document.querySelectorAll('.car-card').forEach((card) => card.classList.add('claiming-closed'));
  hideBanner();
  const status = document.getElementById('claimStatus');
  if (status) {
    status.hidden = false;
    status.textContent = `Season ${season.season_number} is published and the roster is locked. New claims are closed.`;
  }
  document.getElementById('authState').textContent = 'Roster locked for the published season';
}

function showBanner(card) {
  document.getElementById('selNumImg').src = card.querySelector('img').src;
  document.getElementById('selName').textContent = `#${card.dataset.car}`;
  document.getElementById('selTeam').textContent = card.dataset.team;
  document.getElementById('selBanner').classList.add('visible');
}

function updateAllSlotCounts() {
  Object.entries(state.teamMap).forEach(([team, cars]) => {
    const claimed = cars.filter((car) => state.claimedCars.find((entry) => entry.car_number === car)).length;
    const open = Math.max(0, 3 - claimed);
    const el = document.getElementById(`slots-${team}`);

    if (el) {
      el.textContent = open === 0 ? 'FULL' : `${open} spot${open !== 1 ? 's' : ''} open`;
    }
  });
}

function renderClaimedCars() {
  state.claimedCars.forEach((claim) => {
    const el = document.querySelector(`[data-car="${claim.car_number}"]`);
    if (!el || el.querySelector('.car-claimer')) {
      return;
    }

    el.classList.add('claimed');

    const tag = document.createElement('span');
    tag.className = 'car-claimer';
    tag.textContent = formatDriverName(claim);
    el.appendChild(tag);
  });

  updateAllSlotCounts();
}

async function loadClaims() {
  const publishedSeason = await loadPublishedSeason();
  const catalog = await loadTeamCatalog();
  if (catalog.source === 'normalized' && catalog.teams.length) {
    state.teamMap = Object.fromEntries(catalog.teams.map(team => [
      team.slug === 'legacy' ? 'lmc' : team.slug,
      catalog.carNumbersByTeam[team.slug] || [],
    ]));
  }

  const rosterSeason = publishedSeason || await loadCurrentRosterSeason();
  if (rosterSeason) {
    if (publishedSeason) lockClaiming(publishedSeason);
    try {
      const normalized = toLegacyDisplayData({
        ...(await loadNormalizedSeasonData(rosterSeason)),
        catalog,
      });
      state.claimedCars = normalized.claims || [];
      renderClaimedCars();
    } catch (error) {
      console.warn('Could not load the published normalized roster', error);
    }
    return;
  }

  const { data, error } = await supabase
    .from('n26_claim_roster')
    .select('car_number, gamertag, first_name, last_name')
    .order('car_number', { ascending: true });

  if (error) {
    console.warn('Could not load claims', error);
    return;
  }

  state.claimedCars = data || [];
  renderClaimedCars();
}

function closeModal() {
  document.getElementById('modalOverlay').classList.remove('open');
  document.body.style.overflow = '';
}

function openModal() {
  if (state.claimingClosed || !state.selectedCard) {
    return;
  }

  if (!state.user) {
    redirectToAuth('claim.html');
    return;
  }

  const card = state.selectedCard;
  document.getElementById('modalNumImg').src = card.querySelector('img').src;
  document.getElementById('modalDriver').textContent = `#${card.dataset.car}`;
  document.getElementById('modalTeam').textContent = card.dataset.team;
  document.getElementById('hiddenCar').value = card.dataset.car;
  document.getElementById('hiddenDriver').value = card.dataset.driver;
  document.getElementById('hiddenTeam').value = card.dataset.team;
  document.getElementById('claimForm').style.display = 'block';
  document.getElementById('successState').style.display = 'none';
  document.getElementById('modalOverlay').classList.add('open');
  document.body.style.overflow = 'hidden';
}

function selectCar(card) {
  if (state.claimingClosed || card.classList.contains('claimed')) {
    return;
  }

  const team = Object.keys(state.teamMap).find((key) => state.teamMap[key].includes(card.dataset.car));
  const teamClaimed = team ? state.teamMap[team].filter((car) => state.claimedCars.find((entry) => entry.car_number === car)).length : 0;

  if (teamClaimed >= 3) {
    window.alert('This team is full (3 drivers max).');
    return;
  }

  if (state.selectedCard) {
    state.selectedCard.classList.remove('selected');
  }

  if (state.selectedCard === card) {
    state.selectedCard = null;
    hideBanner();
    return;
  }

  card.classList.add('selected');
  state.selectedCard = card;
  showBanner(card);
}

function fillAuthCard(user) {
  const email = document.getElementById('authEmail');
  const stateEl = document.getElementById('authState');
  const signOut = document.getElementById('signOutBtn');
  if (user) {
    email.textContent = user.email || 'Signed in';
    stateEl.textContent = 'Authenticated — you can claim an open car';
    signOut.hidden = false;
    return;
  }
  email.textContent = 'Public roster';
  stateEl.textContent = 'Sign in to claim an open car';
  signOut.hidden = true;
}

function setClaimFormDisabled(disabled) {
  const form = document.getElementById('theForm');
  const submit = document.getElementById('submitBtn');

  Array.from(form.elements).forEach((field) => {
    if ('disabled' in field) {
      field.disabled = disabled;
    }
  });

  submit.disabled = disabled;
}

function showExistingClaimState(claim) {
  state.existingClaim = claim;
  hideBanner();

  if (state.selectedCard) {
    state.selectedCard.classList.remove('selected');
    state.selectedCard = null;
  }

  document.getElementById('authState').textContent = `Already claimed car #${claim.car_number}`;
  document.getElementById('claimForm').style.display = 'none';
  document.getElementById('successState').style.display = 'block';
  document.querySelector('#successState h2').textContent = 'Already Locked In';
  const successCopy = document.querySelector('#successState p');
  successCopy.replaceChildren(
    document.createTextNode(`This account already owns car #${claim.car_number}.`),
    document.createElement('br'),
    document.createTextNode(`${formatDriverName(claim)} is already on the roster.`),
  );
  setClaimFormDisabled(true);
}

async function handleSubmit(event) {
  event.preventDefault();

  if (state.existingClaim || state.claimingClosed) {
    return;
  }

  const btn = document.getElementById('submitBtn');
  btn.disabled = true;
  btn.textContent = 'Saving Claim...';

  const form = event.currentTarget;
  const payload = {
    car_number: document.getElementById('hiddenCar').value,
    driver_name: document.getElementById('hiddenDriver').value,
    team_name: document.getElementById('hiddenTeam').value,
    gamertag: form.gamertag.value.trim(),
    first_name: form.first_name.value.trim(),
    last_name: form.last_name.value.trim(),
    phone: form.phone.value.trim(),
    discord_username: form.discord_username.value.trim().replace(/^@/, ''),
    user_id: state.user.id,
  };

  const { data, error } = await supabase
    .from('n26_claims')
    .insert(payload)
    .select('car_number, gamertag, first_name, last_name')
    .single();

  if (error) {
    btn.disabled = false;
    btn.textContent = 'Lock In My Car';

    if (error.code === '23505') {
      window.alert('That car or account is already locked in. Refresh and pick another open spot.');
      window.location.reload();
      return;
    }

    if (error.code === '42501') {
      window.alert('Your session is missing the permission to create a claim. Apply the new Supabase migration, then try again.');
      return;
    }

    window.alert(error.message || 'Something went wrong. Try again.');
    return;
  }

  state.claimedCars.push(data);
  state.existingClaim = data;

  if (state.selectedCard) {
    state.selectedCard.classList.add('claimed');
    state.selectedCard.classList.remove('selected');

    const tag = document.createElement('span');
    tag.className = 'car-claimer';
    tag.textContent = formatDriverName(data);
    state.selectedCard.appendChild(tag);
    state.selectedCard = null;
  }

  hideBanner();
  updateAllSlotCounts();
  document.getElementById('claimForm').style.display = 'none';
  document.getElementById('successState').style.display = 'block';
}

function closeModalOutside(event) {
  if (event.target === document.getElementById('modalOverlay')) {
    closeModal();
  }
}

function toggleNav() {
  document.getElementById('hamburger').classList.toggle('open');
  document.getElementById('nav-drawer').classList.toggle('open');
}

window.selectCar = selectCar;
window.openModal = openModal;
window.handleSubmit = handleSubmit;
window.toggleNav = toggleNav;
window.closeModalOutside = closeModalOutside;

async function signOut() {
  const { error } = await supabase.auth.signOut({ scope: 'local' });

  if (error) {
    window.alert(error.message);
    return;
  }

  redirectToAuth('claim.html');
}

async function init() {
  const { data: { session } } = await supabase.auth.getSession();
  state.user = session?.user || null;
  fillAuthCard(state.user);
  revealProtectedPage();

  supabase.auth.onAuthStateChange((event, session) => {
    state.user = session?.user || null;
    fillAuthCard(state.user);
    if (event === 'SIGNED_OUT') {
      document.getElementById('claimForm').style.display = 'none';
      document.getElementById('successState').style.display = 'none';
    }
  });

  document.getElementById('signOutBtn').addEventListener('click', signOut);

  document.addEventListener('click', (event) => {
    const hamburger = document.getElementById('hamburger');
    const drawer = document.getElementById('nav-drawer');

    if (hamburger && drawer && !hamburger.contains(event.target) && !drawer.contains(event.target)) {
      hamburger.classList.remove('open');
      drawer.classList.remove('open');
    }
  });

  await loadClaims();
  await renderCupCatalog();

  if (state.user) {
    const { data: existingClaim, error: existingClaimError } = await supabase
      .from('n26_claims')
      .select('car_number, gamertag, first_name, last_name')
      .eq('user_id', state.user.id)
      .maybeSingle();

    if (!existingClaimError && existingClaim) {
      showExistingClaimState(existingClaim);
    }
  }
}

init().catch((error) => {
  console.error(error);
  revealProtectedPage();
  window.alert('Unable to load the protected roster page. Check your Supabase Auth setup and try again.');
});
