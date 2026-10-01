# ShiftSwaap

Swap shifts without the chaos: in a hospital, a restaurant, a fire station or any team that runs on a rota. The whole app is `index.html`. It needs no build step, so any static host can serve it.

## Tenants

| Env | Backend | Data | Who it's for |
|---|---|---|---|
| `prod` | Supabase project `shiftswap-prod` (`wgpgnyapmyvysowdcyvh`) | Real accounts and rooms; starts empty | Real users |
| `dev` | Supabase project `shiftswap-dev` (`byiisadweulvkfuuopra`) | Seeded demo doctors, rooms and shifts | Testing and demos |
| `local` | None | In-browser demo; resets on reload | Quick previews |

### How the page picks a tenant

1. A `?env=dev`, `?env=prod` or `?env=local` URL parameter always wins.
2. Otherwise, `localhost`, `127.0.0.1`, `file://` and any host with `dev` or `staging` in its name (for example `dev.shiftswaap.app`) use **dev**.
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

New rooms start without rules. Admins rename the room and pick its icon in **Settings → Room**.

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

1. **Authentication → Emails → Templates**: paste `supabase/templates/confirmation.html` into **Confirm signup** and `magic_link.html` into **Magic link**. Suggested subjects: `Confirm your ShiftSwaap account` and `Your ShiftSwaap sign-in link`. The emails greet people by name and switch to Spanish when they signed up in Spanish. To change them, edit `supabase/templates/build.mjs` and run `node supabase/templates/build.mjs`.
2. **Authentication → URL Configuration**: set the Site URL to where each tenant is hosted, and add it under Redirect URLs. Confirmation emails, magic links and Google/Facebook sign-in send people back there. Until then, they land on `http://localhost:3000`.
3. **Authentication → Sign In / Providers**: enable Google and Facebook with your OAuth client IDs if you want those buttons to work. Email and password works already.
4. **Prod email**: Supabase's built-in mailer is rate-limited (a few emails per hour). Before real users sign up, add a custom SMTP server under **Authentication → Emails**.
5. Prod is on the free plan, which pauses after a week without activity. Upgrade it before launch.

## Deploy

`.github/workflows/pages.yml` publishes `index.html` to GitHub Pages on every push to `claude/awesome-babbage-fegeqy`. The `supabase/` folder isn't deployed.

- Prod: https://fq-organization.github.io/ShiftSwaap/
- Dev on the same deploy: https://fq-organization.github.io/ShiftSwaap/?env=dev

One-time setup: make the repo public (**Settings → General → Danger Zone**), then under **Settings → Pages → Build and deployment**, set **Source** to **GitHub Actions**.
