import {
  buildAbsoluteUrl,
  getNextPath,
  supabase,
} from './supabase-auth.js';

const nextPath = getNextPath();

const state = {
  mode: 'signin',
  busy: false,
};

function getAuthRedirectError() {
  const params = new URLSearchParams(window.location.hash.replace(/^#/, ''));
  const code = params.get('error_code');
  const description = params.get('error_description');

  if (!code || !description) {
    return null;
  }

  return `${description} (${code})`;
}

function setMessage(text, tone = '') {
  const el = document.getElementById('authMessage');
  el.textContent = text || '';
  el.className = tone ? `auth-message ${tone}` : 'auth-message';
}

function setBusy(busy) {
  state.busy = busy;
  const signInBtn = document.getElementById('signInBtn');
  const signUpBtn = document.getElementById('signUpBtn');
  signInBtn.disabled = busy;
  signUpBtn.disabled = busy;
  signInBtn.textContent = busy && state.mode === 'signin' ? 'Signing In...' : 'Sign In';
  signUpBtn.textContent = busy && state.mode === 'signup' ? 'Creating Account...' : 'Create Account';
  const googleSignInBtn = document.getElementById('googleSignInBtn');
  googleSignInBtn.disabled = busy;
  googleSignInBtn.textContent = busy ? 'Opening Google...' : 'Continue With Google';
}

function setMode(mode) {
  state.mode = mode;
  const title = document.getElementById('authTitle');
  const sub = document.getElementById('authSubtitle');
  const signInBtn = document.getElementById('signInBtn');
  const signUpBtn = document.getElementById('signUpBtn');
  const signInForm = document.getElementById('signInForm');
  const signUpForm = document.getElementById('signUpForm');

  signInBtn.classList.toggle('secondary', mode !== 'signin');
  signUpBtn.classList.toggle('secondary', mode !== 'signup');
  signInForm.hidden = mode !== 'signin';
  signUpForm.hidden = mode !== 'signup';

  if (mode === 'signup') {
    title.textContent = 'Create Your Driver Account';
    sub.textContent = 'Use your email to unlock the protected roster page and claim your car.';
  } else {
    title.textContent = 'Sign In To Claim';
    sub.textContent = 'Your BARL claim page is protected. Sign in to continue to the roster.';
  }

  setMessage('');
}

function redirectToNext() {
  window.location.replace(nextPath);
}

async function handleSignIn(event) {
  event.preventDefault();
  setMode('signin');
  setBusy(true);
  setMessage('');

  const form = event.currentTarget;
  const email = form.email.value.trim();
  const password = form.password.value;

  const { error } = await supabase.auth.signInWithPassword({ email, password });

  if (error) {
    setBusy(false);
    setMessage(error.message, 'error');
    return;
  }

  redirectToNext();
}

async function handleSignUp(event) {
  event.preventDefault();
  setMode('signup');
  setBusy(true);
  setMessage('');

  const form = event.currentTarget;
  const email = form.email.value.trim();
  const password = form.password.value;

  const { data, error } = await supabase.auth.signUp({
    email,
    password,
    options: {
      emailRedirectTo: buildAbsoluteUrl(nextPath),
    },
  });

  if (error) {
    setBusy(false);
    setMessage(error.message, 'error');
    return;
  }

  if (data.session) {
    redirectToNext();
    return;
  }

  setBusy(false);
  setMessage('Check your email to confirm your account, then come back to finish your claim.', 'success');
}

async function handleGoogleSignIn() {
  setBusy(true);
  setMessage('');
  const { error } = await supabase.auth.signInWithOAuth({
    provider: 'google',
    options: { redirectTo: buildAbsoluteUrl(nextPath) },
  });
  if (error) {
    setBusy(false);
    setMessage(error.message, 'error');
  }
}

async function init() {
  document.getElementById('nextPath').textContent = nextPath;
  document.getElementById('signInForm').addEventListener('submit', handleSignIn);
  document.getElementById('signUpForm').addEventListener('submit', handleSignUp);
  document.getElementById('showSignIn').addEventListener('click', () => setMode('signin'));
  document.getElementById('showSignUp').addEventListener('click', () => setMode('signup'));
  document.getElementById('googleSignInBtn').addEventListener('click', handleGoogleSignIn);

  supabase.auth.onAuthStateChange((event, session) => {
    if ((event === 'INITIAL_SESSION' || event === 'SIGNED_IN') && session) {
      redirectToNext();
    }
  });

  const {
    data: { session },
  } = await supabase.auth.getSession();

  if (session) {
    redirectToNext();
    return;
  }

  setMode('signin');

  const redirectError = getAuthRedirectError();
  if (redirectError) {
    setMessage(redirectError, 'error');
    history.replaceState({}, document.title, window.location.pathname + window.location.search);
  }
}

init().catch((error) => {
  console.error(error);
  setMessage('Unable to load Supabase Auth right now. Double-check your project URL and key.', 'error');
});
