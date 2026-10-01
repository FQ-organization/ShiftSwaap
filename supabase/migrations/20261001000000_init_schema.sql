-- ShiftSwap schema. Applied identically to every tenant (dev and prod).
-- Every table has row-level security: people only see rooms they belong to.
-- Text that the client renders as HTML is restricted to characters that are safe to inject.

create schema if not exists private;

-- ---------- tables ----------

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  name text not null check (name ~ '^[^<>"&]{1,60}$'),
  year text check (year in ('R1', 'R2', 'R3', 'R4')),
  avatar smallint not null default 10 check (avatar between 0 and 14),
  notify_requests boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.profile_private (
  id uuid primary key references public.profiles (id) on delete cascade,
  email text,
  phone text check (char_length(phone) <= 40),
  specialty text check (char_length(specialty) <= 80),
  hospital text default 'Hospital Central' check (char_length(hospital) <= 80),
  department text check (char_length(department) <= 80),
  remind boolean not null default true,
  lead_hours smallint not null default 12 check (lead_hours between 1 and 72)
);

create table public.rooms (
  id uuid primary key default gen_random_uuid(),
  name text not null check (name ~ '^[^<>"&]{1,80}$'),
  icon text not null default '🌿' check (char_length(icon) <= 8 and icon !~ '[<>"''&]'),
  bg text not null default '#e3f6ec' check (bg ~ '^#[0-9a-fA-F]{6}$'),
  shift_type text not null default '24h Shift' check (shift_type ~ '^[^<>"&]{1,40}$'),
  allow_sell boolean not null default true,
  approval_mode boolean not null default false,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);

create table public.room_members (
  room_id uuid not null references public.rooms (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  is_admin boolean not null default false,
  joined_at timestamptz not null default now(),
  primary key (room_id, user_id)
);
create index room_members_user_idx on public.room_members (user_id);

create table public.rules (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms (id) on delete cascade,
  name text not null check (name ~ '^[^<>"&]{1,80}$'),
  enabled boolean not null default true,
  type text not null check (type in ('require', 'staff', 'rest', 'max')),
  n int check (n between 0 and 31),
  h int check (h between 0 and 72),
  req jsonb,
  custom boolean not null default false,
  created_at timestamptz not null default now()
);
create index rules_room_idx on public.rules (room_id);

create table public.shifts (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms (id) on delete cascade,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  shift_type text not null check (shift_type ~ '^[^<>"&]{1,40}$'),
  check (ends_at > starts_at),
  unique (room_id, starts_at),
  unique (id, room_id)
);
create index shifts_room_time_idx on public.shifts (room_id, starts_at);

create table public.shift_members (
  shift_id uuid not null,
  room_id uuid not null,
  user_id uuid not null references public.profiles (id) on delete cascade,
  pos smallint not null default 0,
  primary key (shift_id, user_id),
  foreign key (shift_id, room_id) references public.shifts (id, room_id) on delete cascade
);
create index shift_members_user_idx on public.shift_members (user_id);
create index shift_members_room_idx on public.shift_members (room_id);

-- requests and messages share one sequence so the feed has a single order
create sequence public.feed_seq;

create table public.requests (
  id bigint generated always as identity primary key,
  seq bigint not null unique default nextval('public.feed_seq'),
  room_id uuid not null,
  shift_id uuid not null,
  owner_id uuid not null references public.profiles (id) on delete cascade,
  status text not null default 'open' check (status in ('open', 'waiting', 'done', 'void')),
  reason text not null default 'Personal' check (reason in ('Personal', 'Medical appointment', 'Travel', 'Other')),
  importance text not null default 'normal' check (importance in ('normal', 'important', 'urgent')),
  sell boolean not null default false,
  price int not null default 0 check (price between 0 and 100000),
  notified uuid[] not null default '{}',
  declined uuid[] not null default '{}',
  taker_id uuid references public.profiles (id) on delete set null,
  accepted_offer bigint,
  created_at timestamptz not null default now(),
  foreign key (shift_id, room_id) references public.shifts (id, room_id) on delete cascade
);
create index requests_room_idx on public.requests (room_id, seq);

create table public.offers (
  id bigint generated always as identity primary key,
  request_id bigint not null references public.requests (id) on delete cascade,
  room_id uuid not null references public.rooms (id) on delete cascade,
  from_id uuid not null references public.profiles (id) on delete cascade,
  key text not null check (char_length(key) <= 200),
  changes jsonb not null check (jsonb_typeof(changes) = 'array'),
  status text not null default 'pending' check (status in ('pending', 'withdrawn', 'declined', 'accepted', 'void')),
  created_at timestamptz not null default now()
);
create index offers_request_idx on public.offers (request_id);
create index offers_room_idx on public.offers (room_id);

create table public.messages (
  seq bigint primary key default nextval('public.feed_seq'),
  room_id uuid not null references public.rooms (id) on delete cascade,
  user_id uuid references public.profiles (id) on delete set null,
  text text not null check (char_length(text) between 1 and 4000),
  parent bigint,
  sys boolean not null default false,
  tr boolean not null default false,
  created_at timestamptz not null default now(),
  -- system lines are rendered as HTML, so they must not carry markup
  check (not sys or text !~ '[<>]')
);
create index messages_room_idx on public.messages (room_id, seq);

create table public.reactions (
  seq bigint not null,
  user_id uuid not null references public.profiles (id) on delete cascade,
  room_id uuid not null references public.rooms (id) on delete cascade,
  emoji text not null check (emoji in ('👍', '❤️', '😂', '🙏', '🎉', '😮')),
  primary key (seq, user_id)
);
create index reactions_room_idx on public.reactions (room_id);

create table public.notifications (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  room_id uuid references public.rooms (id) on delete cascade,
  text text not null check (char_length(text) <= 300 and text !~ '[<>]'),
  sub text check (char_length(sub) <= 400 and sub !~ '[<>]'),
  importance text not null default 'normal' check (importance in ('normal', 'important', 'urgent')),
  kind text not null default 'req' check (kind in ('req', 'rem')),
  read boolean not null default false,
  dedupe text,
  created_at timestamptz not null default now(),
  unique (user_id, dedupe)
);
create index notifications_user_idx on public.notifications (user_id, id desc);

create table public.invites (
  token text primary key check (token ~ '^[a-z0-9]{8}$'),
  room_id uuid not null references public.rooms (id) on delete cascade,
  created_by uuid references public.profiles (id) on delete set null,
  expires_at timestamptz not null,
  uses int not null default 0,
  revoked boolean not null default false,
  created_at timestamptz not null default now()
);
create index invites_room_idx on public.invites (room_id);

create table public.activity (
  id bigint generated always as identity primary key,
  room_id uuid not null references public.rooms (id) on delete cascade,
  text text not null check (char_length(text) <= 400 and text !~ '[<>]'),
  created_at timestamptz not null default now()
);
create index activity_room_idx on public.activity (room_id, created_at desc);

-- ---------- helpers (private schema: not exposed through the API) ----------

create function private.is_member(r uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.room_members where room_id = r and user_id = (select auth.uid()))
$$;

create function private.is_admin(r uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.room_members where room_id = r and user_id = (select auth.uid()) and is_admin)
$$;

create function private.is_user_member(r uuid, u uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.room_members where room_id = r and user_id = u)
$$;

create function private.shares_room(u uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.room_members a
    join public.room_members b on a.room_id = b.room_id
    where a.user_id = (select auth.uid()) and b.user_id = u)
$$;

create function private.shift_member_count(s uuid) returns int
language sql stable security definer set search_path = '' as $$
  select count(*)::int from public.shift_members where shift_id = s
$$;

revoke all on schema private from public, anon;
grant usage on schema private to authenticated;
revoke all on all functions in schema private from public, anon;
grant execute on all functions in schema private to authenticated;

-- ---------- new users get a profile ----------

create function private.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_name text := left(regexp_replace(coalesce(nullif(trim(new.raw_user_meta_data ->> 'name'), ''),
                                              nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''),
                                              split_part(new.email, '@', 1), 'New user'), '[<>"&]', '', 'g'), 60);
  v_year text := new.raw_user_meta_data ->> 'year';
begin
  if v_name = '' then v_name := 'New user'; end if;
  if v_year not in ('R1', 'R2', 'R3', 'R4') then v_year := null; end if;
  insert into public.profiles (id, name, year, avatar) values (new.id, v_name, v_year, 10 + floor(random() * 5)::int);
  insert into public.profile_private (id, email) values (new.id, new.email);
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function private.handle_new_user();

-- ---------- row-level security ----------

alter table public.profiles enable row level security;
alter table public.profile_private enable row level security;
alter table public.rooms enable row level security;
alter table public.room_members enable row level security;
alter table public.rules enable row level security;
alter table public.shifts enable row level security;
alter table public.shift_members enable row level security;
alter table public.requests enable row level security;
alter table public.offers enable row level security;
alter table public.messages enable row level security;
alter table public.reactions enable row level security;
alter table public.notifications enable row level security;
alter table public.invites enable row level security;
alter table public.activity enable row level security;

create policy "see self and roommates" on public.profiles for select to authenticated
  using (id = (select auth.uid()) or private.shares_room(id));
create policy "edit own profile" on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

create policy "see own private profile" on public.profile_private for select to authenticated
  using (id = (select auth.uid()));
create policy "edit own private profile" on public.profile_private for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

create policy "members see room" on public.rooms for select to authenticated
  using (private.is_member(id));
create policy "admins edit room" on public.rooms for update to authenticated
  using (private.is_admin(id)) with check (private.is_admin(id));

create policy "members see members" on public.room_members for select to authenticated
  using (private.is_member(room_id));

create policy "members see rules" on public.rules for select to authenticated
  using (private.is_member(room_id));
create policy "admins add rules" on public.rules for insert to authenticated
  with check (private.is_admin(room_id));
create policy "admins edit rules" on public.rules for update to authenticated
  using (private.is_admin(room_id)) with check (private.is_admin(room_id));
create policy "admins delete rules" on public.rules for delete to authenticated
  using (private.is_admin(room_id));

create policy "members see shifts" on public.shifts for select to authenticated
  using (private.is_member(room_id));
create policy "members add shifts" on public.shifts for insert to authenticated
  with check (private.is_member(room_id));
create policy "admins edit shifts" on public.shifts for update to authenticated
  using (private.is_admin(room_id)) with check (private.is_admin(room_id));
create policy "admins or last member delete shifts" on public.shifts for delete to authenticated
  using (private.is_admin(room_id) or (private.is_member(room_id) and private.shift_member_count(id) = 0));

create policy "members see shift members" on public.shift_members for select to authenticated
  using (private.is_member(room_id));
create policy "join a shift yourself or admins assign" on public.shift_members for insert to authenticated
  with check (private.is_user_member(room_id, user_id)
              and ((user_id = (select auth.uid()) and private.is_member(room_id)) or private.is_admin(room_id)));
create policy "leave a shift yourself or admins remove" on public.shift_members for delete to authenticated
  using (user_id = (select auth.uid()) or private.is_admin(room_id));

create policy "members see requests" on public.requests for select to authenticated
  using (private.is_member(room_id));
create policy "post a request for your own shift" on public.requests for insert to authenticated
  with check (owner_id = (select auth.uid()) and private.is_member(room_id) and status = 'open'
              and taker_id is null and accepted_offer is null and declined = '{}'
              and exists (select 1 from public.shift_members m where m.shift_id = requests.shift_id and m.user_id = (select auth.uid())));
create policy "owner cancels a request" on public.requests for update to authenticated
  using (owner_id = (select auth.uid()) and status in ('open', 'waiting'))
  with check (owner_id = (select auth.uid()) and status = 'void');

create policy "members see offers" on public.offers for select to authenticated
  using (private.is_member(room_id));
create policy "notified colleagues make offers" on public.offers for insert to authenticated
  with check (from_id = (select auth.uid()) and status = 'pending'
              and exists (select 1 from public.requests r where r.id = offers.request_id and r.room_id = offers.room_id
                          and r.status = 'open' and r.owner_id <> (select auth.uid()) and (select auth.uid()) = any (r.notified)));
create policy "offerer withdraws" on public.offers for update to authenticated
  using (from_id = (select auth.uid()) and status = 'pending')
  with check (from_id = (select auth.uid()) and status = 'withdrawn');
create policy "request owner declines" on public.offers for update to authenticated
  using (status = 'pending' and exists (select 1 from public.requests r where r.id = offers.request_id and r.owner_id = (select auth.uid())))
  with check (status = 'declined');

create policy "members see messages" on public.messages for select to authenticated
  using (private.is_member(room_id));
create policy "members post messages" on public.messages for insert to authenticated
  with check (user_id = (select auth.uid()) and not sys and not tr and private.is_member(room_id));

create policy "members see reactions" on public.reactions for select to authenticated
  using (private.is_member(room_id));
create policy "react yourself" on public.reactions for insert to authenticated
  with check (user_id = (select auth.uid()) and private.is_member(room_id));
create policy "change your reaction" on public.reactions for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()) and private.is_member(room_id));
create policy "remove your reaction" on public.reactions for delete to authenticated
  using (user_id = (select auth.uid()));

create policy "see your notifications" on public.notifications for select to authenticated
  using (user_id = (select auth.uid()));
create policy "mark your notifications read" on public.notifications for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "notify roommates" on public.notifications for insert to authenticated
  with check (private.is_member(room_id) and private.is_user_member(room_id, user_id));

create policy "admins see invites" on public.invites for select to authenticated
  using (private.is_admin(room_id));
create policy "admins create invites" on public.invites for insert to authenticated
  with check (private.is_admin(room_id) and created_by = (select auth.uid()) and uses = 0 and not revoked);
create policy "admins revoke invites" on public.invites for update to authenticated
  using (private.is_admin(room_id)) with check (private.is_admin(room_id));

create policy "members see activity" on public.activity for select to authenticated
  using (private.is_member(room_id));
create policy "members log activity" on public.activity for insert to authenticated
  with check (private.is_member(room_id));

-- ---------- actions that touch several rows or other people's data ----------

create function public.create_room(p_id uuid, p_name text, p_icon text, p_bg text, p_type text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Not signed in'; end if;
  insert into public.rooms (id, name, icon, bg, shift_type, created_by) values (p_id, trim(p_name), p_icon, p_bg, p_type, uid);
  insert into public.room_members (room_id, user_id, is_admin) values (p_id, uid, true);
  insert into public.rules (room_id, name, type, n, h) values
    (p_id, 'Minimum staffing', 'staff', 2, null),
    (p_id, 'Minimum rest', 'rest', null, 11);
  insert into public.messages (room_id, user_id, text, tr) values (p_id, uid, 'Room created ✨', true);
  return p_id;
end $$;

create function public.invite_preview(p_token text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare i public.invites; r public.rooms;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select * into i from public.invites where token = lower(p_token);
  if not found then return jsonb_build_object('status', 'invalid'); end if;
  if i.revoked then return jsonb_build_object('status', 'revoked'); end if;
  if i.expires_at < now() then return jsonb_build_object('status', 'expired'); end if;
  select * into r from public.rooms where id = i.room_id;
  return jsonb_build_object(
    'status', 'ok', 'token', i.token, 'room_id', r.id, 'name', r.name, 'icon', r.icon, 'bg', r.bg,
    'members', (select count(*) from public.room_members where room_id = r.id),
    'invited_by', (select name from public.profiles where id = i.created_by),
    'member', private.is_user_member(r.id, auth.uid()));
end $$;

create function public.join_room(p_token text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare i public.invites; uid uuid := auth.uid(); v_name text; v_room text;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  select * into i from public.invites where token = lower(p_token) for update;
  if not found then raise exception 'That link is not valid.'; end if;
  if i.revoked or i.expires_at < now() then raise exception 'This link is no longer valid.'; end if;
  if private.is_user_member(i.room_id, uid) then return i.room_id; end if;
  insert into public.room_members (room_id, user_id) values (i.room_id, uid);
  update public.invites set uses = uses + 1 where token = i.token;
  select name into v_name from public.profiles where id = uid;
  select name into v_room from public.rooms where id = i.room_id;
  insert into public.messages (room_id, text, sys) values (i.room_id, v_name || ' joined via invite link 👋', true);
  insert into public.notifications (user_id, room_id, text)
    select m.user_id, i.room_id, v_name || ' joined ' || v_room from public.room_members m where m.room_id = i.room_id and m.is_admin;
  return i.room_id;
end $$;

-- "Not now" on a request you were notified about
create function public.pass_request(p_request bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid();
begin
  update public.requests set declined = array_append(declined, uid)
  where id = p_request and uid = any (notified) and not uid = any (declined) and private.is_member(room_id);
end $$;

-- the owner accepts an offer in a room that needs admin approval
create function public.request_approval(p_offer bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare o public.offers; r public.requests;
begin
  select * into o from public.offers where id = p_offer for update;
  if not found or o.status <> 'pending' then raise exception 'This offer is no longer available.'; end if;
  select * into r from public.requests where id = o.request_id for update;
  if r.owner_id <> auth.uid() then raise exception 'Not allowed'; end if;
  if r.status <> 'open' then raise exception 'This request is no longer open.'; end if;
  if not (select approval_mode from public.rooms where id = r.room_id) then raise exception 'Not allowed'; end if;
  update public.requests set status = 'waiting', taker_id = o.from_id, accepted_offer = o.id where id = r.id;
end $$;

-- an admin declines a swap that was waiting for approval
create function public.decline_swap(p_request bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.requests;
begin
  select * into r from public.requests where id = p_request for update;
  if not found or not private.is_admin(r.room_id) then raise exception 'Not allowed'; end if;
  if r.status <> 'waiting' then raise exception 'This request is no longer open.'; end if;
  update public.offers set status = 'declined' where id = r.accepted_offer and status = 'pending';
  update public.requests set status = 'open', taker_id = null, accepted_offer = null where id = r.id;
end $$;

-- apply an accepted offer: the only way shifts change hands
create function public.apply_swap(p_offer bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  o public.offers; r public.requests; c jsonb; n int;
  v_sid uuid; v_out uuid; v_in uuid; v_owner text; v_taker text; v_date text;
begin
  select * into o from public.offers where id = p_offer for update;
  if not found or o.status <> 'pending' then raise exception 'This offer is no longer available.'; end if;
  select * into r from public.requests where id = o.request_id for update;

  if r.status = 'open' then
    if r.owner_id <> uid then raise exception 'Not allowed'; end if;
    if (select approval_mode from public.rooms where id = r.room_id) then raise exception 'Not allowed'; end if;
  elsif r.status = 'waiting' then
    if r.accepted_offer is distinct from o.id or not private.is_admin(r.room_id) then raise exception 'Not allowed'; end if;
  else
    raise exception 'This request is no longer open.';
  end if;

  -- the offer may only move the owner off their shift and, for a swap, the offerer off one of theirs
  n := jsonb_array_length(o.changes);
  if n not in (1, 2) or (r.sell and n <> 1) then raise exception 'That offer is no longer possible.'; end if;
  c := o.changes -> 0;
  if (c ->> 'sid')::uuid <> r.shift_id or (c ->> 'out')::uuid <> r.owner_id or (c ->> 'in')::uuid <> o.from_id then
    raise exception 'That offer is no longer possible.';
  end if;
  if n = 2 then
    c := o.changes -> 1;
    if (c ->> 'sid')::uuid = r.shift_id or (c ->> 'out')::uuid <> o.from_id or (c ->> 'in')::uuid <> r.owner_id then
      raise exception 'That offer is no longer possible.';
    end if;
  end if;
  if not private.is_user_member(r.room_id, o.from_id) then raise exception 'That offer is no longer possible.'; end if;

  for c in select * from jsonb_array_elements(o.changes) loop
    v_sid := (c ->> 'sid')::uuid; v_out := (c ->> 'out')::uuid; v_in := (c ->> 'in')::uuid;
    if not exists (select 1 from public.shift_members where shift_id = v_sid and room_id = r.room_id and user_id = v_out)
       or exists (select 1 from public.shift_members where shift_id = v_sid and user_id = v_in) then
      raise exception 'That offer is no longer possible.';
    end if;
    update public.shift_members set user_id = v_in where shift_id = v_sid and user_id = v_out;
  end loop;

  update public.requests set status = 'done', taker_id = o.from_id where id = r.id;
  update public.offers set status = 'accepted' where id = o.id;
  update public.offers set status = 'void' where request_id = r.id and status = 'pending';
  update public.requests set status = 'void'
    where id <> r.id and status in ('open', 'waiting')
      and shift_id in (select (x ->> 'sid')::uuid from jsonb_array_elements(o.changes) x);

  select name into v_owner from public.profiles where id = r.owner_id;
  select name into v_taker from public.profiles where id = o.from_id;
  select to_char(starts_at at time zone 'UTC', 'Dy FMDD Mon') into v_date from public.shifts where id = r.shift_id;
  insert into public.messages (room_id, text, sys) values (r.room_id,
    format('%s''s %s shift now goes to %s%s ✓', v_owner, v_date, v_taker, case when r.sell then ' · €' || r.price else '' end), true);
end $$;

revoke all on function public.create_room(uuid, text, text, text, text) from public, anon;
revoke all on function public.invite_preview(text) from public, anon;
revoke all on function public.join_room(text) from public, anon;
revoke all on function public.pass_request(bigint) from public, anon;
revoke all on function public.request_approval(bigint) from public, anon;
revoke all on function public.decline_swap(bigint) from public, anon;
revoke all on function public.apply_swap(bigint) from public, anon;
grant execute on function public.create_room(uuid, text, text, text, text) to authenticated;
grant execute on function public.invite_preview(text) to authenticated;
grant execute on function public.join_room(text) to authenticated;
grant execute on function public.pass_request(bigint) to authenticated;
grant execute on function public.request_approval(bigint) to authenticated;
grant execute on function public.decline_swap(bigint) to authenticated;
grant execute on function public.apply_swap(bigint) to authenticated;

-- anonymous visitors get nothing: everything above needs a signed-in user
revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;

-- ---------- realtime: clients refresh when their rooms change ----------

alter publication supabase_realtime add table
  public.rooms, public.room_members, public.rules, public.shifts, public.shift_members,
  public.requests, public.offers, public.messages, public.reactions, public.notifications,
  public.invites, public.activity, public.profiles;
