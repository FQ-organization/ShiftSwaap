-- Shared events. Everyone picks an @handle (lowercase letters, digits, "." and "_", 3 to 20 characters, unique), and
-- can invite other people to their personal events by @handle. A guest sees the invitation, accepts or declines it;
-- an accepted event shows in the guest's calendar too (and counts for clashes). Only the owner edits the event.
-- Guest rows stay: the owner taking someone off the list sets status 'removed'.

-- ---- @handles
alter table public.profiles add column if not exists handle text;
do $$ begin
  alter table public.profiles add constraint profiles_handle_format check (handle ~ '^[a-z0-9][a-z0-9_.]{2,19}$');
exception when duplicate_object then null; end $$;
create unique index if not exists profiles_handle_key on public.profiles (handle);

-- set or change my handle, with a clear message when it's taken or not valid
create or replace function public.set_handle(p_handle text) returns text
language plpgsql security definer set search_path = '' as $$
declare h text := lower(trim(both from ltrim(coalesce(p_handle, ''), '@ ')));
begin
  if auth.uid() is null then raise exception 'Not allowed'; end if;
  if h !~ '^[a-z0-9][a-z0-9_.]{2,19}$' then
    raise exception 'Use 3 to 20 letters, numbers, dots or underscores, starting with a letter or number.';
  end if;
  if exists (select 1 from public.profiles where handle = h and id <> auth.uid()) then
    raise exception 'That @ is taken. Try another one.';
  end if;
  update public.profiles set handle = h where id = auth.uid();
  return h;
end $$;

-- find one person by their exact handle (no searching or listing, so handles can't be harvested)
create or replace function public.find_person(p_handle text) returns table (id uuid, name text, handle text, avatar smallint)
language sql stable security definer set search_path = '' as $$
  select p.id, p.name, p.handle, p.avatar from public.profiles p
  where auth.uid() is not null and p.handle = lower(trim(both from ltrim(coalesce(p_handle, ''), '@ ')))
$$;

-- the demo accounts on dev get handles (no rows on prod)
update public.profiles p set handle = x.h from (values
  ('00000000-0000-4000-8000-000000000001'::uuid, 'francisco'), ('00000000-0000-4000-8000-000000000002'::uuid, 'ana'),
  ('00000000-0000-4000-8000-000000000003'::uuid, 'beatriz'), ('00000000-0000-4000-8000-000000000004'::uuid, 'diogo'),
  ('00000000-0000-4000-8000-000000000005'::uuid, 'ines'), ('00000000-0000-4000-8000-000000000006'::uuid, 'maria'),
  ('00000000-0000-4000-8000-000000000007'::uuid, 'joao'), ('00000000-0000-4000-8000-000000000008'::uuid, 'andre'),
  ('00000000-0000-4000-8000-000000000009'::uuid, 'rita'), ('00000000-0000-4000-8000-000000000010'::uuid, 'tiago')) x (id, h)
where p.id = x.id and p.handle is null;

-- ---- guests
create table if not exists public.event_guests (
  event_id uuid not null references public.personal_events (id),
  user_id uuid not null references public.profiles (id),
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined', 'removed')),
  created_at timestamptz not null default now(),
  primary key (event_id, user_id)
);
create index if not exists event_guests_user_idx on public.event_guests (user_id);
alter table public.event_guests enable row level security;

create or replace function private.owns_event(p_event uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.personal_events where id = p_event and user_id = (select auth.uid()))
$$;
create or replace function private.guest_of(p_event uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.event_guests where event_id = p_event and user_id = (select auth.uid())
                 and status in ('pending', 'accepted'))
$$;

create policy "owners and guests see guests" on public.event_guests for select to authenticated
  using (user_id = (select auth.uid()) or private.owns_event(event_id) or private.guest_of(event_id));
revoke all on public.event_guests from anon, authenticated;
grant select on public.event_guests to authenticated;

-- guests (invited or accepted) can read the event
create policy "guests see shared events" on public.personal_events for select to authenticated
  using (private.guest_of(id));

-- the people on my events and on the events I'm invited to, with names and handles (they may share no room with me)
create or replace function public.event_people() returns table (event_id uuid, user_id uuid, name text, handle text, avatar smallint, status text)
language sql stable security definer set search_path = '' as $$
  with mine as (
    select e.id from public.personal_events e where e.deleted_at is null
      and (e.user_id = auth.uid() or exists (select 1 from public.event_guests g where g.event_id = e.id
                                             and g.user_id = auth.uid() and g.status in ('pending', 'accepted'))))
  select e.id, e.user_id, p.name, p.handle, p.avatar, 'owner' from public.personal_events e join mine m on m.id = e.id
    join public.profiles p on p.id = e.user_id
  union all
  select g.event_id, g.user_id, p.name, p.handle, p.avatar, g.status from public.event_guests g join mine m on m.id = g.event_id
    join public.profiles p on p.id = g.user_id where g.status <> 'removed'
$$;

-- invite people to one of my events (again, after they declined or were removed)
create or replace function public.invite_to_event(p_event uuid, p_users uuid[]) returns void
language plpgsql security definer set search_path = '' as $$
declare e public.personal_events; v_owner text;
begin
  select * into e from public.personal_events where id = p_event;
  if not found or e.user_id is distinct from auth.uid() or e.deleted_at is not null then raise exception 'Not allowed'; end if;
  if coalesce(array_length(p_users, 1), 0) > 50
     or (select count(*) from public.event_guests where event_id = p_event and status <> 'removed') + coalesce(array_length(p_users, 1), 0) > 50 then
    raise exception 'An event can have up to 50 guests.';
  end if;
  select private.short_name(name) into v_owner from public.profiles where id = e.user_id;
  with ins as (
    insert into public.event_guests (event_id, user_id)
    select p_event, u from unnest(p_users) u
    where u <> e.user_id and exists (select 1 from public.profiles where id = u)
    on conflict (event_id, user_id) do update set status = 'pending', created_at = now()
      where public.event_guests.status in ('declined', 'removed')
    returning user_id)
  insert into public.notifications (user_id, text, sub, dedupe)
    select user_id, format('%s invited you to %s', v_owner, e.title), null, 'evinv:' || p_event || ':' || extract(epoch from now())::bigint
    from ins
  on conflict (user_id, dedupe) do nothing;
end $$;

-- the owner takes someone off the guest list
create or replace function public.remove_event_guest(p_event uuid, p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.owns_event(p_event) then raise exception 'Not allowed'; end if;
  update public.event_guests set status = 'removed' where event_id = p_event and user_id = p_user;
end $$;

-- a guest accepts or declines (declining after accepting takes the event off their calendar)
create or replace function public.respond_event(p_event uuid, p_accept boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare e public.personal_events; v_me text; n int;
begin
  select * into e from public.personal_events where id = p_event and deleted_at is null;
  if not found then raise exception 'This event was removed.'; end if;
  update public.event_guests set status = case when p_accept then 'accepted' else 'declined' end
    where event_id = p_event and user_id = auth.uid() and status in ('pending', 'accepted');
  get diagnostics n = row_count;
  if n = 0 then raise exception 'This invitation is no longer open.'; end if;
  select private.short_name(name) into v_me from public.profiles where id = auth.uid();
  insert into public.notifications (user_id, text, sub, dedupe)
    values (e.user_id, format(case when p_accept then '%s accepted %s' else '%s declined %s' end, v_me, e.title), null,
            'evrsp:' || p_event || ':' || auth.uid() || ':' || extract(epoch from now())::bigint)
  on conflict (user_id, dedupe) do nothing;
end $$;

-- removing an event tells the guests who were coming or still invited
create or replace function private.event_removed() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_owner text;
begin
  if old.deleted_at is null and new.deleted_at is not null then
    select private.short_name(name) into v_owner from public.profiles where id = new.user_id;
    insert into public.notifications (user_id, text, sub, dedupe)
      select g.user_id, format('%s cancelled %s', v_owner, new.title), null, 'evdel:' || new.id
      from public.event_guests g where g.event_id = new.id and g.status in ('pending', 'accepted')
    on conflict (user_id, dedupe) do nothing;
  end if;
  return new;
end $$;
create or replace trigger personal_events_removed after update of deleted_at on public.personal_events
  for each row execute function private.event_removed();

revoke all on function public.set_handle(text), public.find_person(text), public.event_people(),
  public.invite_to_event(uuid, uuid[]), public.remove_event_guest(uuid, uuid), public.respond_event(uuid, boolean) from public, anon;
grant execute on function public.set_handle(text), public.find_person(text), public.event_people(),
  public.invite_to_event(uuid, uuid[]), public.remove_event_guest(uuid, uuid), public.respond_event(uuid, boolean) to authenticated;

do $$ begin
  alter publication supabase_realtime add table public.event_guests;
exception when duplicate_object then null; end $$;

-- ---- PART 2: run in the SQL editor (the tools that applied part 1 can't run statements that remove rows or objects).
-- When an account is removed, its guest rows go with it; same for an event row (events are only ever hidden, though).
-- alter table public.event_guests drop constraint event_guests_event_id_fkey,
--   add constraint event_guests_event_id_fkey foreign key (event_id) references public.personal_events (id) on delete cascade;
-- alter table public.event_guests drop constraint event_guests_user_id_fkey,
--   add constraint event_guests_user_id_fkey foreign key (user_id) references public.profiles (id) on delete cascade;
