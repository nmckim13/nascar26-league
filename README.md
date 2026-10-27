# NASCAR 26 Racing League

Static public site and normalized Supabase-backed league administration for an
eight-race season with eight teams, three seats per team, and a 24-driver
target field.

## Current State

Season 1 is intentionally still a draft. The live project currently has the
team and car catalog plus the imported roster, but it must not be published
until all 24 driver identities and the complete positions 1-24 points schedule
are approved. Public pages fail closed to a clear prelaunch state until then.

## Orb Development

Amp runs executable `.agents/setup` when preparing a fresh project snapshot.
It installs the Node version pinned in `.node-version` (matching CI's Node 22
major), checks Python 3 for static previews, and installs locked development
dependencies with `npm ci`. The number-art builder's `sharp` dependency and its
prebuilt image libraries are installed without running package lifecycle scripts.
Subsequent orbs can reuse the prepared snapshot; warm setup uses npm's cache.

The setup adds a repository-scoped login-shell hook so Amp and supervised
services use the same Node installation. `.agents/resume` checks that Node and
the image dependency are ready without installing packages or authenticating.
Run `.agents/setup` manually to repair missing prerequisites.

Use `npm test` for the existing league, rulebook, and claim-flow checks. The
public HTML has no bundler or build step. Asset generators still require their
source inputs; setup does not regenerate tracked artwork.

The static preview is declared in `.amp/services.yaml`. Run
`amp orb services ensure` to start it and print its public portal URL, or open
**BARL Preview** from Amp's Portals tab to start it on demand. Amp supervises the
server across CLI updates and orb pause/resume. The service uses Python 3 from
setup, needs no additional dependencies, and checks `/rules.html` for readiness.

Setup does not create an environment file, log in to external services, start
databases, apply Supabase migrations, or change production data. Authenticated
API testing still requires the server-side variables listed in `.env.example`;
provide those through Amp secrets, never through the setup scripts. Static
previews do not execute the Vercel `/api` handlers.

## Verify Locally

From the repository root:

```sh
node scripts/verify-league-model.js
node scripts/verify-rulebook-fixture.js
node --check api/league-admin.js
node --check scripts/admin-page.js
git diff --check
```

`npm test` also covers opening consecutive rounds through the commissioner API
with a simulated Supabase transport. CI separately runs the actual result-entry
and appeal-correction SQL plus claim promotion/account linking against a
disposable PostgreSQL 15 database:

```sh
psql -X -v ON_ERROR_STOP=1 -d league_test -f scripts/verify-race-results.sql
psql -X -v ON_ERROR_STOP=1 -d league_test -f scripts/verify-claim-sync.sql
```

Use an empty local test database and a superuser for these SQL fixtures; never
run them against the live Supabase project. They load the relevant schema and
RPC migrations, supply minimal Supabase auth and legacy intake prerequisites,
and roll back all test objects and data. They are not full Supabase
migration/deployment tests.

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
