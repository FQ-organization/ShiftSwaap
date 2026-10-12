-- Personal calendar: everyone has their own events, visible only to them. The app shows them with the person's shifts
-- from every room, so clashes stand out, and warns before taking a shift that clashes. People without a room can use
-- Swapecito as a plain personal calendar.
-- Removing an event hides it (deleted_at), like rooms: nothing is deleted.

create table public.personal_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  title text not null check (title ~ '^[^<>]{1,80}$' and title !~ '^\s*$'),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  all_day boolean not null default false,
  color text not null default '#e8edff' check (color ~ '^#[0-9a-fA-F]{6}$'),
  created_at timestamptz not null default now(),
  deleted_at timestamptz,
  check (ends_at > starts_at),
  check (ends_at - starts_at <= interval '62 days')
);
create index personal_events_user_time_idx on public.personal_events (user_id, starts_at);

alter table public.personal_events enable row level security;
create policy "people see their own events" on public.personal_events for select to authenticated
  using (user_id = (select auth.uid()));
create policy "people add their own events" on public.personal_events for insert to authenticated
  with check (user_id = (select auth.uid()) and deleted_at is null);
create policy "people edit their own events" on public.personal_events for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
revoke all on public.personal_events from anon;
-- only these columns change after an event is added (not its owner or id)
revoke update on public.personal_events from authenticated;
grant update (title, starts_at, ends_at, all_day, color, deleted_at) on public.personal_events to authenticated;

alter publication supabase_realtime add table public.personal_events;

-- usage events: as in 20261014000000, plus calendar_event (a count only, never the title)
create or replace function private.event_ok(n text, p jsonb) returns boolean
language sql immutable set search_path = '' as $$
  select n in ('admin_approved', 'admin_declined', 'blocked', 'csv_import', 'invite_created', 'invite_joined',
               'language_changed', 'logout', 'member_removed', 'message', 'notification', 'offer_declined', 'offer_sent',
               'owner_added', 'password_changed', 'profile_edited', 'reaction', 'report_created', 'request_cancelled',
               'request_posted', 'room_created', 'room_deleted', 'room_left', 'rule_created', 'session', 'shift_added',
               'swap_completed', 'thread_reply', 'client_error',
               'calendar_event')
    and private.event_props_ok(p)
$$;
