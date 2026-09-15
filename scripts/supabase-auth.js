import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm';

const SUPABASE_URL = 'https://txipxisumngvzkuqsysq.supabase.co';
const SUPABASE_PUBLIC_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZ2dWpoa3J5cXpobWVtb2plZHhzIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODMzNDAwOTksImV4cCI6MjA5ODkxNjA5OX0.9TmFZBDBig8qG1iostl4-GoQL10CBgKSL_DvBHJ7lIc';

const SUPABASE_NEW_PUBLIC_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InR4aXB4aXN1bW5ndnprdXFzeXNxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODkwNzExMTYsImV4cCI6MjEwNDY0NzExNn0.NxrJIAkWWfg-5ezHni_z56IRmLD9HHxM-VAALiT22io';
export const supabase = createClient(SUPABASE_URL, SUPABASE_NEW_PUBLIC_KEY, {
  auth: {
    autoRefreshToken: true,
    detectSessionInUrl: true,
    flowType: 'pkce',
    storageKey: 'barl-auth-session',
    persistSession: true,
  },
});

function currentPage() {
  const parts = window.location.pathname.split('/').filter(Boolean);
  return parts[parts.length - 1] || 'index.html';
}

function sanitizeNext(next) {
  if (!next || typeof next !== 'string') {
    return null;
  }

  if (next.startsWith('//') || next.includes('://')) {
    return null;
  }

  if (!/^[A-Za-z0-9._/?#=&%-]+$/.test(next)) {
    return null;
  }

  return next;
}

export function getNextPath(fallback = 'claim.html') {
  const params = new URLSearchParams(window.location.search);
  return sanitizeNext(params.get('next')) || fallback;
}

export function redirectToAuth(next = currentPage()) {
  const target = sanitizeNext(next) || 'claim.html';
  window.location.replace(`auth.html?next=${encodeURIComponent(target)}`);
}

export function buildAbsoluteUrl(path) {
  return new URL(path, window.location.href).toString();
}

export async function requireUser(next = currentPage()) {
  const {
    data: { session },
  } = await supabase.auth.getSession();

  if (!session) {
    redirectToAuth(next);
    return null;
  }

  const {
    data: { user },
    error,
  } = await supabase.auth.getUser();

  if (error || !user) {
    await supabase.auth.signOut({ scope: 'local' });
    redirectToAuth(next);
    return null;
  }

  return { session, user };
}
