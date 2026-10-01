# ShiftSwap

Swap hospital shifts without the chaos. The whole app is `index.html`. It needs no build step, so any static host can serve it.

## Tenants

| Env | Backend | Data | Who it's for |
|---|---|---|---|
| `prod` | Supabase project `shiftswap-prod` (`wgpgnyapmyvysowdcyvh`) | Real accounts and rooms; starts empty | Real users |
| `dev` | Supabase project `shiftswap-dev` (`byiisadweulvkfuuopra`) | Seeded demo doctors, rooms and shifts | Testing and demos |
| `local` | None | In-browser demo; resets on reload | Quick previews |

### How the page picks a tenant

1. A `?env=dev`, `?env=prod` or `?env=local` URL parameter always wins.
2. Otherwise, `localhost`, `127.0.0.1`, `file://` and any host with `dev` or `staging` in its name (for example `dev.shiftswap.app`) use **dev**.
3. Every other host uses **prod**.

Pages outside prod show a small orange `DEV` or `LOCAL DEMO` badge. Prod hides all demo features: the demo logins, the "Acting as" switcher, the demo clock, the scenario buttons and the developer dashboard.

The URLs and publishable keys are in the `TENANTS` block at the top of the script in `index.html`. Publishable keys are designed to ship in the browser. Row-level security (RLS) on every table is what protects the data.

### Demo accounts (dev only)

Every demo account uses the password `demo1234`:
`francisco@`, `ana@`, `beatriz@`, `diogo@`, `ines@`, `maria@`, `joao@`, `andre@`, `rita@` and `tiago@hospitalcentral.example`.
Maria is the admin of Emergency Medicine and João is the admin of Intensive Care.

## Database

- `supabase/migrations/20261001000000_init_schema.sql`: the schema, RLS policies, realtime setup and server functions. It's already applied to both tenants. Apply any future migration to **both**.
- `supabase/seed/gen-dev-seed.mjs` generates `supabase/seed/dev_seed.sql` from the same generators the local demo uses. **Never run the seed against prod.**

What the database enforces:
- People only see rooms they belong to. Contact details (`profile_private`) are visible only to their owner.
- Only admins can change rules, room settings and invites, or assign other people to shifts.
- Shifts change hands only through `apply_swap()`. It checks that the caller owns the request (or is an admin, in approval mode) and that the offer moves only the owner and the offerer.
- Text that the app renders as HTML (names, room names, notifications, system lines) can't contain markup.

Not enforced by the database yet: the scheduling rules themselves (minimum staffing, junior + senior coverage, rest hours, monthly maximum). The app checks them before every swap or added shift, but a hand-crafted API call could skip those checks. Moving them into `apply_swap()` is the next hardening step.

## Setup still needed in the Supabase dashboard

These settings aren't reachable through the API I used, so they need to be set by hand, per project:

1. **Authentication → URL Configuration**: set the Site URL to where each tenant is hosted, and add it under Redirect URLs. Confirmation emails, magic links and Google/Facebook sign-in send people back there. Until then, they land on `http://localhost:3000`.
2. **Authentication → Sign In / Providers**: enable Google and Facebook with your OAuth client IDs if you want those buttons to work. Email and password works already.
3. **Prod email**: Supabase's built-in mailer is rate-limited (a few emails per hour). Before real users sign up, add a custom SMTP server under **Authentication → Emails**.
4. Prod is on the free plan, which pauses after a week without activity. Upgrade it before launch.
