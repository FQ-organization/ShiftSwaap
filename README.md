# Swapecito

The GitHub repository and the site address keep the old name, `ShiftSwaap`.

Swap shifts without the chaos: in a hospital, a restaurant, a fire station or any team that runs on a rota. The whole app is `index.html`. It needs no build step, so any static host can serve it.

## Tenants

| Env | Backend | Data | Who it's for |
|---|---|---|---|
| `prod` | Supabase project `shiftswap-prod` (`wgpgnyapmyvysowdcyvh`) | Real accounts and rooms; starts empty | Real users |
| `dev` | Supabase project `shiftswap-dev` (`byiisadweulvkfuuopra`) | Seeded demo doctors, rooms and shifts | Testing and demos |
| `local` | None | In-browser demo; resets on reload | Quick previews |

### How the page picks a tenant

1. A `?env=dev`, `?env=prod` or `?env=local` URL parameter always wins.
2. Otherwise, `localhost`, `127.0.0.1`, `file://` and any host with `dev` or `staging` in its name (for example `dev.swapecito.app`) use **dev**.
3. Every other host uses **prod**.

Pages outside prod show a small orange `DEV` or `LOCAL DEMO` badge. Prod hides all demo features: the demo logins, the "Acting as" switcher, the demo clock, the scenario buttons and the developer dashboard.

The URLs and publishable keys are in the `TENANTS` block at the top of the script in `index.html`. Publishable keys are designed to ship in the browser. Row-level security (RLS) on every table is what protects the data.

### Demo accounts (dev only)

Every demo account uses the password `demo1234`. The demo rooms use the tags R1–R4 (residency years), but they're ordinary tags that admins can rename or replace:
`francisco@`, `ana@`, `beatriz@`, `diogo@`, `ines@`, `maria@`, `joao@`, `andre@`, `rita@` and `tiago@hospitalcentral.example`.
Maria is the admin of Emergency Medicine and João is the admin of Intensive Care.

## Rooms, tags and rules

Each room's admins create **tags** that describe its people (role, level, skill, team…), give them to members, and build **rules** from them:

| Rule | Example |
|---|---|
| Who must be on each shift: one or more conditions, all required | at least 1 *Senior* **and** at most 2 *Trainee* |
| Rest between shifts, for people with chosen tags (or everyone) | *Drivers*: at least 11 hours |
| Maximum shifts per week or month, for people with chosen tags (or everyone) | Everyone: at most 5 per week |

A condition with no tags counts anyone. A person's tags belong to the room, not to their account, so the same person can be *Senior* in one room and have no tags in another. A tag can't be deleted while a rule uses it.

New rooms start without rules. Admins rename the room and pick its icon in **Settings → Room**, where they can also **delete** it after typing its name. Deleting sets `rooms.deleted_at`: every access check treats the room as gone, its invite links are revoked and the other members get a notification. The rows stay in the database, so the project owner can restore a room from the SQL editor:
`update public.rooms set deleted_at = null, deleted_by = null where name = '…';` (revoked invite links stay revoked).

**Reports** (Settings → Reports, admins only): pick a month and get the shifts, hours worked, requests, swaps, shifts taken as is, sales (count and €), still open and cancelled, plus a line per person. Download it as a CSV spreadsheet or print / save it as PDF. A month covers the shifts that start in it. On dev and prod, `room_report()` computes it on the server and refuses anyone who isn't an admin of the room.

Whoever creates a room is its first admin. Admins can make other members admins, or remove admins, in **Settings → People**. A room always keeps at least one admin.

## Developer dashboard (owner only)

Usage metrics: active users, sessions, sign-ups, requests, swaps, messages, the exchange funnel and per-room counts. The app records counts only, never message text. Only accounts on a tenant's `app_admins` list can open the dashboard, and the database enforces this too:
- `app_events` can only be read by owners, and `dev_rooms()` refuses everyone else.
- The `app_admins` list itself can't be read through the API at all.
- An account counts as owner only if its email is on the list **and confirmed**, so registering someone else's address gets you nothing.

The button is in **Profile & settings**, and only owners see it. Local demo mode has no dashboard.

**Managing owners:** in the dashboard, the **Dashboard owners** card adds an owner by email and removes one. Dev and prod keep separate lists. The last owner can't be removed. Removing an owner marks them as revoked instead of deleting the row, so there's a record of who had access. The emails live in the database, not in this public repo. From the SQL editor:

```sql
select public.add_app_admin('you@example.com');  -- only works when run as an owner; otherwise:
insert into public.app_admins (email) values ('you@example.com') on conflict (email) do update set revoked_at = null;
```

## Database

- `supabase/migrations/`: the schema, RLS policies, realtime setup and server functions. Every file is already applied to both tenants. Apply any future migration to **both**.
  - `20261002000000_room_tags_and_generic_rules.sql` adds `room_tags`, `member_tags` and `room_rules`, and converts the old rules and residency years. It only adds things: the old `rules` table and the `profiles.year` column stay in place, unused. To remove them, run this once per project in the SQL editor:
    `drop table public.rules; alter table public.profiles drop column year;`
- `supabase/seed/gen-dev-seed.mjs` generates `supabase/seed/dev_seed.sql` from the same generators the local demo uses. **Never run the seed against prod.**

What the database enforces:
- People only see rooms they belong to. Contact details (`profile_private`) are visible only to their owner.
- Only admins can change rules, tags, who has which tag, room settings and invites, or assign other people to shifts.
- Shifts change hands only through `apply_swap()`. It checks that the caller owns the request (or is an admin, in approval mode) and that the offer moves only the owner and the offerer.
- Text that the app renders as HTML (names, room names, notifications, system lines) can't contain markup.

Not enforced by the database yet: the scheduling rules themselves (minimum staffing, junior + senior coverage, rest hours, monthly maximum). The app checks them before every swap or added shift, but a hand-crafted API call could skip those checks. Moving them into `apply_swap()` is the next hardening step.

## Setup still needed in the Supabase dashboard

These settings aren't reachable through the API I used, so they need to be set by hand, per project:

1. **Authentication → Emails → Templates**: paste `supabase/templates/confirmation.html` into **Confirm signup** and `recovery.html` into **Reset password**. Suggested subjects: `Confirm your Swapecito account` and `Reset your Swapecito password`. (`magic_link.html` is kept for later; the app no longer offers magic-link sign-in.) The emails greet people by name and switch to Spanish when they signed up in Spanish. To change them, edit `supabase/templates/build.mjs` and run `node supabase/templates/build.mjs`.
2. **Authentication → URL Configuration**: set the Site URL to where each tenant is hosted, and add it under Redirect URLs. Confirmation and password-reset emails send people back there, so the reset link only works for addresses listed there. Until then, they land on `http://localhost:3000`.
3. **Prod email**: Supabase's built-in mailer is rate-limited (a few emails per hour). Before real users sign up, add a custom SMTP server under **Authentication → Emails**.
4. Prod is on the free plan, which pauses after a week without activity. Upgrade it before launch.

## Accounts and passwords

- Passwords need at least 10 characters, with letters and a number. The app checks this on sign-up, reset and change. Set the same minimum on the server (Authentication → Providers → Email → password requirements), because the API can be called without the app. Existing passwords, like the dev demo accounts' `demo1234`, keep working.
- **Forgot password?** on the sign-in screen emails a link (`resetPasswordForEmail`). The link opens **Choose a new password**. The confirmation looks the same whether or not the email has an account.
- **Profile → Password** changes it after checking the current password. Both flows can sign out every other device.
- The Supabase library is a fixed copy in `vendor/` (`supabase-js` 2.117.2, checked against npm's published checksum). It's served with the site and loaded with a `sha384` integrity hash, so a modified file is refused. To update: `npm pack @supabase/supabase-js@<version>`, copy `package/dist/umd/supabase.js` to `vendor/supabase-js-<version>.js`, then update the `<script>` tag's file name and its `integrity` (`openssl dgst -sha384 -binary FILE | openssl base64 -A`).

## App icon

`icons/icon.svg` is the source. `icons/icon-full.svg` (iPhone) and `icons/icon-maskable.svg` (Android, which may crop to a circle) are the same drawing on a full square background. The PNGs (`favicon-32`, `apple-touch-icon` 180 px, `icon-192`, `icon-512`, `icon-maskable-512`) are exported from them. `manifest.webmanifest` makes the site installable on a phone's home screen. The login screen draws the icon inline, and the emails load `icon-192.png` from the deployed site.

## Deploy

`.github/workflows/pages.yml` publishes `index.html`, `manifest.webmanifest`, `icons/` and `vendor/` to GitHub Pages on every push to `claude/awesome-babbage-fegeqy`. The `supabase/` folder isn't deployed.

- Prod: https://fq-organization.github.io/ShiftSwaap/
- Dev on the same deploy: https://fq-organization.github.io/ShiftSwaap/?env=dev

### Custom domain (swapecito.com)

1. **DNS, at the domain registrar.** For `swapecito.com`, add four `A` records pointing to `185.199.108.153`, `185.199.109.153`, `185.199.110.153` and `185.199.111.153`. Optionally add four `AAAA` records too: `2606:50c0:8000::153`, `2606:50c0:8001::153`, `2606:50c0:8002::153`, `2606:50c0:8003::153`. For `www`, add a `CNAME` pointing to `fq-organization.github.io`. Delete any other `A`/`CNAME` records for those names (for example the registrar's parking page).
2. **GitHub → repo Settings → Pages → Custom domain:** enter `swapecito.com` and save. Once the DNS check passes, tick **Enforce HTTPS**; the certificate can take up to an hour. No `CNAME` file is needed, because this repo deploys with Actions. `www.swapecito.com` and the old `github.io` address then redirect to `swapecito.com`.
3. **Recommended: verify the domain** under GitHub organization **Settings → Pages → Add a domain**, with the `TXT` record it shows. That stops anyone else's GitHub Pages site from claiming it.
4. **Supabase, both projects → Authentication → URL Configuration:** set the Site URL to `https://swapecito.com` and add `https://swapecito.com/**` to the Redirect URLs, so confirmation emails come back to the new address.

Prod is then `https://swapecito.com` and dev is `https://swapecito.com/?env=dev`.

One-time setup: make the repo public (**Settings → General → Danger Zone**), then under **Settings → Pages → Build and deployment**, set **Source** to **GitHub Actions**.
