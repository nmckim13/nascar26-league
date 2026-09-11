# BARL League Operations

## What Is Live

The normalized league model is deployed to Supabase project `txipxisumngvzkuqsysq`. Season 1 is currently a private `draft` with eight draft races and no imported driver identities yet. Legacy compatibility tables exist only for migration and diagnostics and are not a public fallback.

The public site reads the normalized season only after it is opened and fails closed to a prelaunch state until then. The commissioner console is `/admin.html` and requires a Supabase account whose profile has `is_admin = true`.

After a season is certified, use **Prepare next season draft** in the commissioner console. The server derives the equal cap from certified OVRs, creates a new immutable ruleset, copies the eight-race schedule, and seeds the prior full-time roster and active seats into the editable draft. Multi-season contracts are not duplicated because their recorded season range carries them forward from the original signing record.

## Commissioner Workflow

1. Add the remaining real driver identities in `/admin.html`. For several new drivers, use **Bulk Roster Import**; the database creates permanent identities, registers them, and assigns seats in one transaction. A driver identity is permanent; do not create a new driver just because that driver changes numbers.
2. Use Seat Desk to assign, transfer, or release a seat. An initial assignment is direct; a transfer requires recorded consent from the driver, releasing team, and destination team. The transfer first closes the old assignment, then creates the new one, and the old number is immediately available to another driver. Any active multi-season contract follows the driver to the new seat; destination-team loyalty and cap charge are recalculated.
3. Use Contract Desk after a driver has an active destination seat. The database derives the certified prior-season OVR (or the explicit newcomer value), calculates the exact cap charge, verifies term and loyalty eligibility, locks the season during signing, rejects duplicate or over-cap offers, and logs each signing as a transaction.
4. Before roster lock, use **Release contract** only for a documented early termination or published cap-compliance exception. Releasing a contract does not silently remove the driver's seat; use Seat Desk separately when the roster change is approved.
5. Configure and open a race, then paste the result JSON from the Race Desk. Results are validated against the ruleset and stored as drafts.
6. Publish the race only after the full-time field has a row for every driver, starter count is recorded, and valid qualifying data is present, unless qualifying was explicitly canceled or voided. Publication opens the 48-hour appeal window.
7. Finalize the race after the appeal window closes. Ratings consume only finalized certified results; corrections create an immutable audit row before a result is replaced.
8. If a round cannot count toward the championship, use **Void selected race** with a reason. The race remains auditable, receives certified void status, and is excluded from points, starts, ratings, and denominators.
9. After the season is certified, use **Expire contracts** once. Multi-season contracts remain active until their recorded end season; expired contracts and releases remain in the permanent transaction history.
10. For a future draft season, open the market once. Opening the market first reprices every carried contract from the newly certified prior-season OVR, recalculates loyalty, and checks the published cap. The database then enforces a 48-hour incumbent-only renewal window followed by five days of free agency; incumbent extensions are available during that renewal window, and after the closing time, new contracts are rejected.

For Season 1 onboarding, public claims remain in the legacy intake table until the commissioner reviews them. Use **Sync authenticated claims into draft** to promote each claim into its permanent driver identity and normalized seat atomically; the public claim form never writes normalized league state directly.

Routine transfers stop at roster lock. For a documented withdrawal after the opener, use **Midseason Replacement**; it ends the old seat, releases the departing driver's current contract, assigns the replacement to that same team/car, preserves both driver identities and past results, and records contract-release, withdrawal, and signing transactions. The replacement is a reserve entry and earns separate driver statistics, while the occupied seat's points remain part of the team championship total.

An early contract release is recorded as a transaction and blocks term discounts for the released driver and the releasing team in the immediately following season. Existing unrelated discounts are preserved; the block does not affect loyalty calculations or later seasons.

Each normalized result is tied to a historical seat assignment. The RPC resolves the matching assignment from `driver_id`, `team_id`, and `car_number`; include `seat_assignment_id` explicitly when entering a reserve or a historical transfer. The result keeps its own team/car snapshot, so later roster moves never rewrite past team points. During the appeal window, use the correction control so the old row is audited before the corrected row is republished.

Provisional ratings use only completed, non-voided rounds to date. Qualifying credit is divided by every valid qualifying session in that period, while DNS entries receive no start or qualifying credit. A canceled or voided qualifying session is excluded rather than treated as a missed session.

Final rating certification and season certification are service-only database transitions. They lock the season, verify the complete roster, certified race count, approved ruleset, and certified rating count, and then update the final state atomically.

Disqualification policy: a started driver marked `disqualified` keeps the official finish position for published ordering and tiebreaks, but receives zero championship points and zero finish-quality credit. The start still counts for attendance, and valid qualifying counts because the driver started. DNS cannot be marked disqualified.

Public profiles read only published or certified seasons. Driver history is keyed by permanent driver ID and retains each season's team, seat, starts, wins, points, and certified OVR. Team owner names and honors are optional commissioner metadata; cap usage and latest contract expiration are exposed only as team-level aggregates.

## Activation Gate

Before publishing the 24-driver season, approve a versioned points schedule that defines positions 13-24. The current draft intentionally has `points_schedule_status = pending_24_position_extension`; no missing values are inferred. Paste the complete 1-24 map and a new version into **Approve new points version**; it preserves positions 1-12, enforces non-increasing integer values, and moves the draft season to the new approved ruleset atomically.

The publish operation is atomic: it refuses to open the season unless there are exactly 24 full-time entries and 24 active seats, verifies each of the eight teams has exactly three seats, requires the points schedule to be explicitly marked `approved`, and creates any missing Season 1 introductory contracts at 50 credits before locking the roster.

## Deployment Variables

Set these Vercel environment variables for the commissioner API:

- `SUPABASE_URL`: `https://vvujhkryqzhmemojedxs.supabase.co`
- `SUPABASE_SERVICE_ROLE_KEY`: the Supabase service-role key, server-side only
- `SUPABASE_ANON_KEY`: optional; if omitted, the API uses the service key for the server-side Auth check
- `SUPABASE_WEBHOOK_SECRET`: required by the Discord claim webhook and must match the secret configured on the Supabase webhook
- `DISCORD_BOT_TOKEN`: required only for automatic Discord announcements and team-role assignment
- `COMMISSIONER_DISCORD_ID`: optional Discord user ID used for manual-fallback mentions

Never put `SUPABASE_SERVICE_ROLE_KEY` in HTML, browser JavaScript, GitHub, or a public Vercel variable.
