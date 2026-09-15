'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
const runtimeFiles = [
  ...fs.readdirSync(root).filter(file => file.endsWith('.html')),
  ...fs.readdirSync(path.join(root, 'scripts')).filter(file => file.endsWith('.js')).map(file => `scripts/${file}`),
];
const auth = read('scripts/supabase-auth.js');
const claim = read('scripts/claim-page.js');
const styles = read('n26.css');
const migration = read('supabase/migrations/20260915182528_authenticated_claim_table_select.sql');
const claimWebhook = read('api/claim-webhook.js');
const discordMigration = read('supabase/migrations/20260915185410_discord_approval_webhook.sql');
const discordLockMigration = read('supabase/migrations/20260915191253_lock_discord_webhook_trigger.sql');

assert.match(auth, /https:\/\/txipxisumngvzkuqsysq\.supabase\.co/);
runtimeFiles.forEach((file) => {
  const tokens = read(file).match(/eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/g) || [];
  tokens.forEach((token) => {
    const payload = JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString('utf8'));
    if (payload.role === 'anon') assert.equal(payload.ref, 'txipxisumngvzkuqsysq', `${file} uses a stale Supabase key`);
  });
});
assert.match(auth, /storageKey:\s*'barl-auth-session'/);
assert.match(auth, /persistSession:\s*true/);
assert.match(claim, /supabase\.auth\.getUser\(\)/);
assert.match(claim, /\.from\('n26_claims'\)[\s\S]*?\.insert\(payload\)/);
assert.match(claim, /\.in\('approval_status', \['pending', 'approved'\]\)/);
assert.doesNotMatch(claim, /Apply the new Supabase migration/);
assert.ok(claim.lastIndexOf('revealProtectedPage();') > claim.indexOf('await loadClaims();'));
assert.match(styles, /\[hidden\]\s*\{\s*display:\s*none\s*!important;\s*\}/);
assert.match(migration, /grant select on table public\.n26_claims to authenticated;/i);
assert.match(claimWebhook, /if \(!WEBHOOK_SECRET \|\| !DISCORD_TOKEN\)/);
assert.match(claimWebhook, /payload\?\.type === 'PING'/);
assert.match(discordMigration, /create extension if not exists pg_net/i);
assert.match(discordMigration, /n26_notify_discord_on_approval/);
assert.match(discordMigration, /where name = 'n26_discord_webhook_secret'/);
assert.doesNotMatch(discordMigration, /new\.phone/);
assert.match(discordLockMigration, /revoke execute on function public\.notify_discord_on_claim\(\) from anon/i);
assert.match(discordLockMigration, /revoke execute on function public\.notify_discord_on_claim\(\) from authenticated/i);

console.log('Claim flow verified: persistent auth, owned-row lookup, authenticated insert, PostgREST return access, and approval notifications.');
