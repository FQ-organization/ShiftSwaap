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

## Languages

English, Spanish and Portuguese (Portugal). **System** (the default) follows the browser's language. People can pick another in **Profile & settings → Language**; the choice is remembered on that device (`localStorage`). Phone notifications use the same language as the app. Pages are written in English and translated as they render: `ES`/`PT` hold whole texts, `ES_RX`/`PT_RX` hold texts with names or numbers, and `SENT`/`PT_SENT` hold sentences inside longer messages, all keyed by the English text. `tx(en, es, pt)` is for text that's built in code. Without a `pt` argument, the Portuguese comes from `PT`.

## Rooms, tags and rules

Each room's admins create **tags** that describe its people (role, level, skill, team…), give them to members, and build **rules** from them:

| Rule | Example |
|---|---|
| Who must be on each shift: one or more conditions, all required | at least 1 *Senior* **and** at most 2 *Trainee* |
| Rest between shifts, for people with chosen tags (or everyone) | *Drivers*: at least 11 hours |
| Maximum shifts per week or month, for people with chosen tags (or everyone) | Everyone: at most 5 per week |

A condition with no tags counts anyone. A shift is complete only when all its "at least" and "exactly" conditions hold; until then it waits for teammates and members can join it. Its own members can leave it with **Remove me** only if that adds no violation and worsens none except the headcount shortfall it already has (the app checks this; the database lets anyone leave). A person's tags belong to the room, not to their account, so the same person can be *Senior* in one room and have no tags in another. A tag can't be deleted while a rule uses it (the database refuses it too); a rule left pointing at a deleted tag says "(deleted tag)" and counts nobody for it.

Rule numbers are whole numbers: rest 0 to 168 hours, a maximum of 0 to 366 shifts per week or month (0 means "none"), and 0 to 99 people per condition. A decimal or out-of-range value is rounded into range, and a blank box keeps the old value, each with a message.

**Import from CSV** (Schedule): rows with the same date form one shift. Admins can import anyone, and the preview counts the rule warnings they would override. A member can import only their own shifts, and each row gets the same checks as **Add my shift**, in date order: a row that would break their rest, maximum or overlap is left out, with its reason under its row number. New shifts and their people are saved in one call, `add_shifts()`, so nothing is half-saved.

**Time zone.** Each room has one (`rooms.tz`). Shifts run 08:00 to 08:00 in it, and so do "today", past days, the weeks and months that rules count, and report months. Everyone sees the room's dates, wherever they are, and the app adds a note such as "Lisbon time" when the room's zone differs from the viewer's. New rooms take their creator's time zone. Admins change it in **Settings → Room**. `set_room_tz()` then moves every upcoming shift so it keeps its day and its 08:00 start and end in the new zone. Shifts that have started don't move. The first upcoming shift can't start in the past or before the running shift ends, so it then starts when it was due to (or when that shift ends) and still ends at 08:00; on a later change it gets its whole day back, so changing the zone and changing it back restores the schedule. If that would leave a shift with no time at all (a jump of more than 24 hours while a shift is running), the change is refused until that shift starts. Before saving, the app tells the admin about a shortened shift, a gap, or a new rule problem, and they can cancel. The app and `add_shifts()` refuse a new shift on top of an existing one (`20261013000000_medium_fixes.sql`); the direct inserts of the previous app version and admin edits of a shift's times aren't checked for overlaps. The rooms that existed before time zones were added are set to `Europe/Lisbon`.

New rooms start without rules. Room names have 1 to 80 characters, without `< > " &`, on create and rename (the same test as the database). Room, tag and rule names are shown exactly as typed in every language; only the local demo's built-in names are translated. Admins rename the room and pick its icon in **Settings → Room**, where they can also **delete** it after typing its name. Deleting sets `rooms.deleted_at`: every access check treats the room as gone, its invite links are revoked and the other members get a notification. The rows stay in the database, so the project owner can restore a room from the SQL editor:
`update public.rooms set deleted_at = null, deleted_by = null where name = '…';` (revoked invite links stay revoked).

**Swaps, sales and approval.** A sale's price is a whole number of euros from 1 to 100000 (`requests.price` is an int). The price box takes "40", "40,00" or "40.0"; "1,5", "0.4" or "1e3" get a message instead of being rounded, and the stored price is the one shown everywhere (chip, notifications, feed, reports). When a request closes, its pending offers close too and their makers are told: the owner cancelled it, or its shift changed hands in another swap (that request's owner is told as well). In a room with **Admin approval**, an accepted swap waits for an admin; an admin who is part of it (owner or taker) doesn't get the card or the notification while another admin can decide, but if every admin is part of it they decide, so it never gets stuck. While it waits, the owner can still **Cancel request** and the taker can **Withdraw offer** (the request opens again for other offers); the other person is told. A swap still waiting when one of its shifts starts expires: nothing moves, the request closes (or opens again if only the taker's shift started) and both people are told.

**Group feed and threads.** A message has up to 4000 characters (`messages.text`); the box stops there and shows a counter from 3500. Unsent text is kept per room, per thread and per person until you leave the app, so it never shows up in another room. Enter sends, except while a Japanese, Chinese or Korean input method is composing. When a message arrives while you're at the bottom of the chat, it scrolls to show it; if you've scrolled up to read, it keeps your place and shows a **New messages ↓** button. On dev and prod, writes are queued and sent in order. If the server can't be reached, a write is retried 3 times. If a write is refused, only the writes made by the same action are dropped (a failed reply sends no notification), the others still go through, and a message that wasn't saved goes back into its box with a note saying so.

**Reports** (Settings → Reports, admins only): pick a month and get the shifts, hours worked, requests, swaps, shifts taken as is, sales (count and €), still open, cancelled and closed automatically, plus a line per person. Download it as a CSV spreadsheet or print / save it as PDF. A month covers the shifts that start in it. The list runs from next month (the schedule ahead) back a year; it opens on last month, this month or next month, the first that has shifts. **Still open** counts requests that can still be filled; **Cancelled**, the ones their owner cancelled (or whose owner removed themselves from the shift); **Closed automatically**, the ones the app closed (the shift changed hands in another swap, a swap waiting for an admin expired, the owner left or was removed) and the ones still open when their shift started. The database records why a request closed in `requests.close_reason` (`cancelled` or `system`, set by a trigger; requests closed before it existed got a best guess). On dev and prod, `room_report()` computes it on the server and refuses anyone who isn't an admin of the room.

Whoever creates a room is its first admin. Admins can make other members admins, or remove admins, in **Settings → People**. A room always keeps at least one admin.

Members leave a room in **Settings → Leave room**, once they've given their upcoming shifts to someone else. The last admin can't leave. Admins remove someone in **Settings → People → Remove from room**: that takes the person off upcoming shifts (started ones stay), cancels their open requests and offers, revokes the invite links they created and notifies them. To come back they need a link made after the removal: older links, whoever made them, don't let them in (`room_removals`). The admins are notified when someone leaves.

## Developer dashboard (owner only)

Usage metrics: active users, sessions, sign-ups, requests, swaps, messages, the exchange funnel and per-room counts. It loads the newest 20,000 events of the last 61 days; if there are more, it says so and from which day the counts are complete. In the funnel a request counts as "Got at least one offer" once, on the day of its first offer, and the step never shows more than the requests posted. The app records counts only, never message text. Only accounts on a tenant's `app_admins` list can open the dashboard, and the database enforces this too:
- `app_events` can only be read by owners, and `dev_rooms()` refuses everyone else.
- The `app_admins` list itself can't be read through the API at all.
- An account counts as owner only if its email is on the list **and confirmed**, so registering someone else's address gets you nothing.

The button is in **Profile & settings**, and only owners see it. Local demo mode has no dashboard.

**Managing owners:** in the dashboard, the **Dashboard owners** card adds an owner by email and removes one. Dev and prod keep separate lists. The last owner can't be removed: only owners who can open the dashboard (a confirmed account) count, so an address nobody has confirmed doesn't keep the dashboard reachable. Removing an owner marks them as revoked instead of deleting the row, so there's a record of who had access. The emails live in the database, not in this public repo. From the SQL editor:

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
- Shifts change hands only through `apply_swap()`. It checks that the caller owns the request (or, in approval mode, is an admin who may decide on it) and that the offer moves only the owner and the offerer.
- Text that the app renders as HTML (names, room names, notifications, system lines) can't contain markup.
- Shifts that have started are locked: nobody can join, leave, add, edit or delete them, request or offer them, or approve a swap that involves one (`20261009000000_past_shifts_are_locked.sql`). In the calendar, today is circled and past days are greyed out.

- The room's rules (`20261010000000_rules_on_server_and_room_time_zones.sql`). `private.rule_violations_sev()` evaluates them the same way the app does: who must be on each shift, rest hours, maximum per week or month, and no overlapping shifts. A change is refused if it adds a violation or makes one worse (more shifts over a maximum, a bigger shortfall or excess on a shift, less rest, more overlap). Changes that keep or reduce a violation are allowed, so a schedule that already breaks a rule doesn't freeze the room (`20261011000000_rules_refuse_worse_violations.sql`, which replaced the older `private.rule_violations()`, now unused).
  - `apply_swap()` refuses any swap, sale or giveaway that adds or worsens a violation.
  - A member who adds themselves to a shift can't add or worsen a violation: their rest, maximum or overlap, or the shift's "at most" / "exactly" conditions. A shift stays incomplete, and open to join, until every "at least" / "exactly" condition (tagged or not) is met. Admins can still assign anyone: the app shows them the broken rule and asks them to confirm the override.
  - `add_shifts()` creates new shifts with their people in one transaction (Add shift, Add my shift and CSV import use it), so a refused person can't leave an empty shift behind; if any shift is refused, none is added. It allows what the table policies allow (a member adds only themselves, admins anyone in the room, only shifts that haven't started) and refuses a shift on top of an existing one. The direct inserts of the previous app version still work (`20261013000000_medium_fixes.sql`).
  - A tag can't be deleted while a rule uses it, and a rule can only use tags of its own room (`20261013000000_medium_fixes.sql`).
- Swaps and sales (`20261013000000_medium_fixes.sql`):
  - A new sale needs a price of at least €1 (a trigger, so old €0 sales can still be cancelled).
  - A request that closes (cancelled, done, or voided because its shift changed hands in another swap) closes its pending offers. Withdrawing, declining or voiding the offer a swap waits on opens the request again (or closes it, if its shift has started).
  - `apply_swap()` and `decline_swap()` refuse an admin who is part of the swap while another admin of the room is not ("Another admin has to approve a swap you are part of.").
  - `expire_swaps(room)` expires the room's waiting swaps whose shifts have started and notifies the owner and the taker once; the app calls it when it sees one (on load and as time passes). `decline_swap()` on such a swap closes it instead of reopening it.
- Notifications, the activity log and offers (`20261013000000_medium_fixes.sql`):
  - The notifications about approvals and decisions are written by the server: `request_approval()` tells the admins who can decide and the offerer, `apply_swap()` the owner, the taker, the other offerers and the owners (and offerers) of the requests it closes, `decline_swap()` the owner and the taker (with the reason when the swap can't happen any more). Live, the app doesn't send them; the copies older app versions send are skipped. The same goes for the ones `join_room()`, `leave_room()`, `remove_member()` and `expire_swaps()` write.
  - What an app sends someone else is checked (`private.vet_notification()`): kind `req`, no dedupe key, unread. Important or urgent only between a request's owner and a colleague it notified, at the request's importance; otherwise it arrives as normal. A member who isn't an admin of the room can only send the app's texts, starting with their own name (`Ana S. declined your offer`, `… replied in …`, `… wants to change …`, `… can swap with you on …`, `… joined your … shift`, `… cancelled the request for …`, `… withdrew from the swap on …`). Anything else is skipped without an error. A new notification text that members send needs adding there.
  - Reminders (kind `rem`) and dedupe keys are only for yourself, and the keys start with your user id, so nobody can use up someone else's reminder.
  - Activity lines from a member who isn't an admin must be the app's, starting with their own name (`private.vet_activity()`); every line records who wrote it (`activity.user_id`).
  - The app can only change an offer's or a request's `status` (column privileges); everything else is changed by the server's functions.
  - Live, the app cancels a request with `cancel_request()` and withdraws an offer with `withdraw_offer()`. Every function that changes swaps locks in the same order: the room, then the request(s), then the offers, so two of them never deadlock. The previous app version's direct updates still work. Its direct cancel locks in that order too; its direct withdraw locks the offer before the request, so withdrawing the offer a swap waits on while someone else is changing that request (an admin deciding, the owner cancelling) is refused with "This offer is no longer available." instead of waiting, which could deadlock.
  - Still possible: an admin can send members of their room any text and write any activity line (their user id is recorded); a member can send roommates as many of their own name-prefixed texts as they like, with any second line; mute preferences are applied by the sender's app.
- The server numbers the feed (`messages.seq`, `requests.seq`) and stamps `created_at` on messages, requests, activity and usage events, whatever the client sends. `leave_room()` and `remove_member()` take the room's row lock (`for no key update`, so it doesn't block inserts that reference the room), like `set_room_admin()`, so a room always keeps an admin. `join_room()` refuses someone removed from the room when the link is older than the removal. Usage events only accept the app's event names and props keys and types (`20261012000000_server_seq_leave_rooms_event_props.sql`).

## Setup still needed in the Supabase dashboard

These settings aren't reachable through the API I used, so they need to be set by hand, per project:

1. **Authentication → Emails → Templates**: paste `supabase/templates/confirmation.html` into **Confirm signup** and `recovery.html` into **Reset password**. Suggested subjects: `Confirm your Swapecito account` and `Reset your Swapecito password`. (`magic_link.html` is kept for later; the app no longer offers magic-link sign-in.) The emails greet people by name and switch to Spanish or Portuguese when the person signed up in that language. Templates pasted before Portuguese was added only know English and Spanish, so paste them again. To change them, edit `supabase/templates/build.mjs` and run `node supabase/templates/build.mjs`.
2. **Authentication → URL Configuration**: set the Site URL to where each tenant is hosted, and add it under Redirect URLs. Confirmation and password-reset emails send people back there, so the reset link only works for addresses listed there. Until then, they land on `http://localhost:3000`.
3. **Prod email**: Supabase's built-in mailer is rate-limited (a few emails per hour). Before real users sign up, add a custom SMTP server under **Authentication → Emails**.
4. Prod is on the free plan, which pauses after a week without activity. Upgrade it before launch.

## Accounts and passwords

- Passwords need at least 10 characters, with letters and a number. The app checks this on sign-up, reset and change. Set the same minimum on the server (Authentication → Providers → Email → password requirements), because the API can be called without the app. Existing passwords, like the dev demo accounts' `demo1234`, keep working.
- **Forgot password?** on the sign-in screen emails a link (`resetPasswordForEmail`). The link opens **Choose a new password**. The confirmation looks the same whether or not the email has an account.
- **Profile → Password** changes it after checking the current password. Both flows can sign out every other device.
- **Log out** signs out this device only.
- After **Create account** without an instant session, the app shows the same text whether or not the email already has an account: check your email, or sign in or reset your password if you already have one. Signing in before confirming offers **Send a new confirmation link**.
- An expired or already-used email link (`#error=…&error_code=otp_expired`) opens the sign-in screen with an explanation and **Send a new confirmation link** (when the address marks it as a reset link, **Reset your password** opens instead), and the error is removed from the address.
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
