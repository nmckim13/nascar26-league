import { requireUser, supabase } from './supabase-auth.js';

let auth;
const esc = value => String(value ?? '').replace(/[&<>'"]/g, character => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', "'":'&#39;', '"':'&quot;' }[character]));
async function call(method = 'GET', body) {
  const response = await fetch('/api/driver-portal', { method, headers: { Authorization: `Bearer ${auth.session.access_token}`, 'Content-Type': 'application/json' }, body: body ? JSON.stringify(body) : undefined });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok || !payload.ok) throw new Error(payload.error || 'Portal request failed.');
  return payload.result;
}
function text(id, value) { document.getElementById(id).textContent = value ?? '—'; }
function render(data) {
  document.getElementById('loading').hidden = true;
  document.getElementById('adminLink').hidden = !data.commissioner;
  if (!data.driver) { document.getElementById('pending').hidden = false; return; }
  document.getElementById('content').hidden = false;
  text('driverName', data.driver.display_name); text('teamName', data.team?.name || 'Seat pending'); text('carNumber', data.assignment ? `#${data.assignment.car_number}` : '—'); text('seasonName', data.season?.name);
  const image = document.getElementById('carImage'); if (data.assignment) { image.src = `https://cf.nascar.com/data/images/carbadges/1/${encodeURIComponent(data.assignment.car_number)}.png`; image.alt = `Car number ${data.assignment.car_number}`; }
  const contract = data.contract;
  document.getElementById('contract').innerHTML = contract ? `<div class="facts"><div class="fact"><span>Status</span><strong>${esc(contract.status)}</strong></div><div class="fact"><span>Length</span><strong>${esc(contract.original_term_seasons)} season${contract.original_term_seasons === 1 ? '' : 's'}</strong></div><div class="fact"><span>Runs through</span><strong>Season ${esc(contract.end_season)}</strong></div><div class="fact"><span>Team charge</span><strong>${(Number(contract.cap_charge_cents || 0) / 100).toFixed(2)} credits</strong></div></div>` : '<p class="muted">No active contract has been recorded yet.</p>';
  document.getElementById('teammates').innerHTML = data.teammates.length ? data.teammates.map(mate => `<div class="mate"><span>${esc(mate.display_name)}</span><strong>#${esc(mate.car_number)}</strong></div>`).join('') : '<p class="muted">No teammates have been assigned yet.</p>';
  const form = document.getElementById('profileForm'); ['display_name','gamertag','first_name','last_name'].forEach(name => { form.elements[name].value = data.driver[name] || ''; });
}
async function init() {
  auth = await requireUser('driver.html'); if (!auth) return;
  render(await call());
  document.getElementById('profileForm').addEventListener('submit', async event => { event.preventDefault(); const message = document.getElementById('message'); message.textContent = 'Saving…'; message.className = 'message'; try { render(await call('PATCH', Object.fromEntries(new FormData(event.currentTarget).entries()))); message.textContent = 'Profile updated.'; } catch (error) { message.textContent = error.message; message.className = 'message error'; } });
  document.getElementById('signOut').addEventListener('click', async () => { await supabase.auth.signOut({ scope:'local' }); location.replace('index.html'); });
}
init().catch(error => { document.getElementById('loading').textContent = error.message; document.getElementById('loading').classList.add('error'); });
