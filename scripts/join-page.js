import { requireUser } from './supabase-auth.js';

requireUser('join.html').catch((error) => {
  console.error('Unable to verify Join access', error);
});
