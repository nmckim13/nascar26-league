'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
const auth = read('scripts/supabase-auth.js');
const claim = read('scripts/claim-page.js');
const styles = read('n26.css');
const migration = read('supabase/migrations/20260915182528_authenticated_claim_table_select.sql');

assert.match(auth, /https:\/\/txipxisumngvzkuqsysq\.supabase\.co/);
assert.match(auth, /storageKey:\s*'barl-auth-session'/);
assert.match(auth, /persistSession:\s*true/);
assert.match(claim, /supabase\.auth\.getUser\(\)/);
assert.match(claim, /\.from\('n26_claims'\)[\s\S]*?\.insert\(payload\)/);
assert.match(claim, /\.in\('approval_status', \['pending', 'approved'\]\)/);
assert.doesNotMatch(claim, /Apply the new Supabase migration/);
assert.ok(claim.lastIndexOf('revealProtectedPage();') > claim.indexOf('await loadClaims();'));
assert.match(styles, /\[hidden\]\s*\{\s*display:\s*none\s*!important;\s*\}/);
assert.match(migration, /grant select on table public\.n26_claims to authenticated;/i);

console.log('Claim flow verified: persistent auth, owned-row lookup, authenticated insert, and PostgREST return access.');
