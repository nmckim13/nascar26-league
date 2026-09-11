# NASCAR 26 Racing League

Static public site and normalized Supabase-backed league administration for an
eight-race season with eight teams, three seats per team, and a 24-driver
target field.

## Current State

Season 1 is intentionally still a draft. The live project currently has the
team and car catalog plus the imported roster, but it must not be published
until all 24 driver identities and the complete positions 1-24 points schedule
are approved. Public pages fail closed to a clear prelaunch state until then.

## Verify Locally

From the repository root:

```sh
node scripts/verify-league-model.js
node scripts/verify-rulebook-fixture.js
node --check api/league-admin.js
node --check scripts/admin-page.js
git diff --check
```

## Launch Sequence

1. Set `SUPABASE_SERVICE_ROLE_KEY` only in Vercel server-side environment
   variables. Never add it to HTML, JavaScript, Git, or chat.
2. Sign in at `admin.html` and import or claim the remaining real drivers.
3. Assign exactly 24 full-time drivers across the eight three-seat teams. Keep
   additional drivers in the reserve pool.
4. Approve a versioned, explicit points map for every position 1 through 24.
5. Complete roster lock, race setup, result certification, rating certification,
   and the final season publication gates in the admin console.

## Google Sign-In

The auth page includes Google OAuth. In the Supabase dashboard, open
**Authentication > Providers > Google**, enable it, and enter the Google OAuth
client ID and secret. In Google Cloud, add the production site origin
`https://nascar26-league.vercel.app` and the Supabase callback URL shown on the
Supabase provider page. Add the local origin only while developing locally.

The database functions enforce these gates atomically. A driver identity is
permanent and separate from a car number, so a transfer may select any open
seat; the old number then becomes unowned without rewriting historical data.
