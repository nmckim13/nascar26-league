import { supabase } from './supabase-auth.js';

function updateAuthLinks(session) {
  document.querySelectorAll('.nav-cta, .drawer-cta').forEach((link) => {
    link.href = session ? 'driver.html' : 'auth.html?next=driver.html';
    link.textContent = session ? 'Driver Portal →' : 'Log In / Join →';
  });
}

async function init() {
  const { data: { session } } = await supabase.auth.getSession();
  updateAuthLinks(session);
  supabase.auth.onAuthStateChange((_event, nextSession) => updateAuthLinks(nextSession));
}

init().catch((error) => console.warn('Unable to update auth navigation', error));
