-- 1. The server numbers the feed. messages.seq and requests.seq come from feed_seq whatever the client sends, so nobody
--    can take future numbers (which blocked every room's messages, requests, joins and swaps) or pin a post to the end.
--    created_at is the server's clock too. Rows a client already numbered past the sequence get fresh numbers.
-- 2. Members can leave a room and admins can remove people. Someone removed can't come back through a link made before
--    the removal (theirs or anyone's), only through a new one. A room always keeps an admin: leave_room, remove_member and
--    set_room_admin take the room's row lock first (no key update, so inserts that point at the room aren't blocked),
--    so two of them can't each count the other as the remaining admin. Swaps, approvals and joining a shift take the
--    same lock first, so nobody gets a shift while they leave or are removed.
-- 3. Usage events only take the event names and props the app sends, so no text reaches the owner's dashboard.

-- ---------- 1. feed numbers ----------

-- repair: rows numbered past the sequence (only a client could do that) get fresh numbers, in their order;
-- their reactions and thread replies follow them. The fresh numbers skip every number past the sequence that's in use,
-- so nothing collides and no number is worked out from what clients wrote (any bigint, so no arithmetic on them).
-- (before the triggers below exist, since the requests trigger keeps seq as it is)
lock table public.messages, public.requests, public.reactions in exclusive mode;
do $$
declare v_last bigint; v bigint; x record;
begin
  select case when is_called then last_value else 0 end into v_last from public.feed_seq;
  create temp table fx on commit drop as
    select t, old, room_id, row_number() over (order by old, t) as rn, null::bigint as new
    from (select 'm'::text as t, seq as old, room_id from public.messages where seq > v_last
          union all select 'r', seq, room_id from public.requests where seq > v_last) f;
  -- whatever points past the sequence at no such row in its room points at nothing
  delete from public.reactions r where r.seq > v_last and not exists (select 1 from fx f where f.old = r.seq and f.room_id = r.room_id);
  update public.messages m set parent = null
    where m.parent > v_last and not exists (select 1 from fx f where f.old = m.parent and f.room_id = m.room_id);
  if not exists (select 1 from fx) then return; end if;
  create index on fx (old); create index on fx (rn);
  for x in select rn from fx order by rn loop
    loop v := nextval('public.feed_seq'); exit when not exists (select 1 from fx where old = v); end loop;
    update fx set new = v where rn = x.rn;
  end loop;
  -- every new number is unused, so these never collide; a message and a request with the same number: replies follow the message
  update public.messages m set seq = f.new from fx f where f.t = 'm' and m.seq = f.old;
  update public.requests r set seq = f.new from fx f where f.t = 'r' and r.seq = f.old;
  update public.reactions r set seq = f.new
    from (select distinct on (old, room_id) old, room_id, new from fx order by old, room_id, t) f where r.seq = f.old and r.room_id = f.room_id;
  update public.messages m set parent = f.new
    from (select distinct on (old, room_id) old, room_id, new from fx order by old, room_id, t) f where m.parent = f.old and m.room_id = f.room_id;
end $$;

create function private.server_stamps() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'UPDATE' then
    new.seq := old.seq; new.created_at := old.created_at;
  else
    if tg_table_name in ('messages', 'requests') then new.seq := nextval('public.feed_seq'); end if;
    new.created_at := now();
  end if;
  return new;
end $$;
revoke all on function private.server_stamps() from public, anon;

create trigger messages_server_stamps before insert on public.messages
  for each row execute function private.server_stamps();
create trigger requests_server_stamps before insert or update on public.requests
  for each row execute function private.server_stamps();
create trigger activity_server_stamps before insert on public.activity
  for each row execute function private.server_stamps();
create trigger app_events_server_stamps before insert on public.app_events
  for each row execute function private.server_stamps();

-- ---------- 2. leaving a room, removing someone ----------

-- who was removed from which room, and when: links created before that don't let them back in
create table public.room_removals (
  room_id uuid not null references public.rooms (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  removed_at timestamptz not null default now(),
  primary key (room_id, user_id)
);
alter table public.room_removals enable row level security;  -- no policies: only the functions below use it
revoke all on public.room_removals from anon, authenticated;

-- true when the caller was removed from the invite's room after that link was made
create function private.removed_since(i public.invites) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.room_removals x
                 where x.room_id = i.room_id and x.user_id = auth.uid() and i.created_at <= x.removed_at)
$$;
revoke all on function private.removed_since(public.invites) from public, anon, authenticated;

-- takes someone out of a room: off its upcoming shifts (started ones are history; a shift left with nobody goes),
-- their open requests and offers cancelled, a swap waiting for approval with them as the taker back to open.
-- Their tags go with the membership (foreign key). Returns how many upcoming shifts they were taken off.
create function private.drop_member(p_room uuid, p_user uuid) returns int
language plpgsql security definer set search_path = '' as $$
declare v_ids uuid[];
begin
  update public.offers set status = 'void' where room_id = p_room and from_id = p_user and status = 'pending';
  update public.requests set status = 'open', taker_id = null, accepted_offer = null
    where room_id = p_room and status = 'waiting' and taker_id = p_user;
  update public.offers set status = 'void' where status = 'pending'
    and request_id in (select id from public.requests where room_id = p_room and owner_id = p_user and status in ('open', 'waiting'));
  update public.requests set status = 'void' where room_id = p_room and owner_id = p_user and status in ('open', 'waiting');
  with gone as (
    delete from public.shift_members m using public.shifts s
    where s.id = m.shift_id and m.room_id = p_room and m.user_id = p_user and s.starts_at > now()
    returning m.shift_id)
  select coalesce(array_agg(shift_id), '{}') into v_ids from gone;
  delete from public.shifts s where s.id = any (v_ids)
    and not exists (select 1 from public.shift_members m where m.shift_id = s.id);
  delete from public.room_members where room_id = p_room and user_id = p_user;
  return cardinality(v_ids);
end $$;
revoke all on function private.drop_member(uuid, uuid) from public, anon, authenticated;

-- a member leaves: not while they still hold upcoming shifts (they give them away first), and not the last admin
create function public.leave_room(p_room uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); v_room text; v_name text;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  -- one membership change at a time per room, so it always keeps an admin
  select name into v_room from public.rooms where id = p_room and deleted_at is null for no key update;
  if not found or not private.is_member(p_room) then raise exception 'Not allowed'; end if;
  if exists (select 1 from public.shift_members m join public.shifts s on s.id = m.shift_id
             where m.room_id = p_room and m.user_id = uid and s.starts_at > now()) then
    raise exception 'You still have upcoming shifts in this room. Give them away before you leave.';
  end if;
  if private.is_admin(p_room) and not exists (select 1 from public.room_members where room_id = p_room and is_admin and user_id <> uid) then
    raise exception 'You are the only admin. Make someone else an admin first, or delete the room.';
  end if;
  perform private.drop_member(p_room, uid);
  select private.short_name(name) into v_name from public.profiles where id = uid;
  insert into public.activity (room_id, text) values (p_room, v_name || ' left the room');
  insert into public.notifications (user_id, room_id, text)
    select m.user_id, p_room, v_name || ' left the room ' || v_room from public.room_members m where m.room_id = p_room and m.is_admin;
end $$;

-- an admin removes someone else (to leave, they use leave_room); returns how many upcoming shifts were left without them
create function public.remove_member(p_room uuid, p_user uuid) returns int
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); v_room text; v_who text; v_name text; n int;
begin
  select name into v_room from public.rooms where id = p_room and deleted_at is null for no key update;
  if not found or not private.is_admin(p_room) then raise exception 'Not allowed'; end if;
  if p_user = uid or not private.is_user_member(p_room, p_user) then raise exception 'Not allowed'; end if;
  n := private.drop_member(p_room, p_user);
  -- the links they created stop working, and no link made before now lets them back in (see join_room)
  update public.invites set revoked = true where room_id = p_room and created_by = p_user and not revoked;
  insert into public.room_removals (room_id, user_id) values (p_room, p_user)
    on conflict (room_id, user_id) do update set removed_at = now();
  select private.short_name(name) into v_who from public.profiles where id = uid;
  select private.short_name(name) into v_name from public.profiles where id = p_user;
  insert into public.activity (room_id, text) values (p_room, v_who || ' removed ' || v_name || ' from the room');
  -- they can't see the room any more, so the notification isn't tied to it
  insert into public.notifications (user_id, room_id, text) values (p_user, null, v_who || ' removed you from ' || v_room);
  return n;
end $$;

-- same lock as above: two admins demoting each other at once can't leave the room without one
create or replace function public.set_room_admin(p_room uuid, p_user uuid, p_admin boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform 1 from public.rooms where id = p_room for no key update;
  if not private.is_admin(p_room) then raise exception 'Not allowed'; end if;
  if not private.is_user_member(p_room, p_user) then raise exception 'Not allowed'; end if;
  if not p_admin and (select count(*) from public.room_members where room_id = p_room and is_admin and user_id <> p_user) = 0 then
    raise exception 'A room needs at least one admin.';
  end if;
  update public.room_members set is_admin = p_admin where room_id = p_room and user_id = p_user;
end $$;

-- as before, plus: someone removed from the room needs a link made after the removal
create or replace function public.invite_preview(p_token text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare i public.invites; r public.rooms;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select * into i from public.invites where token = lower(p_token);
  if not found then return jsonb_build_object('status', 'invalid'); end if;
  if i.revoked then return jsonb_build_object('status', 'revoked'); end if;
  if i.expires_at < now() then return jsonb_build_object('status', 'expired'); end if;
  if not private.is_user_member(i.room_id, auth.uid()) and private.removed_since(i) then
    return jsonb_build_object('status', 'removed');
  end if;
  select * into r from public.rooms where id = i.room_id;
  return jsonb_build_object(
    'status', 'ok', 'token', i.token, 'room_id', r.id, 'name', r.name, 'icon', r.icon, 'bg', r.bg,
    'members', (select count(*) from public.room_members where room_id = r.id),
    'invited_by', (select name from public.profiles where id = i.created_by),
    'member', private.is_user_member(r.id, auth.uid()));
end $$;

create or replace function public.join_room(p_token text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare i public.invites; uid uuid := auth.uid(); v_name text; v_room text;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  select * into i from public.invites where token = lower(p_token) for update;
  if not found then raise exception 'That link is not valid.'; end if;
  if i.revoked or i.expires_at < now() then raise exception 'This link is no longer valid.'; end if;
  if private.is_user_member(i.room_id, uid) then return i.room_id; end if;
  if private.removed_since(i) then raise exception 'You were removed from this room. Ask an admin for a new invite link.'; end if;
  insert into public.room_members (room_id, user_id) values (i.room_id, uid);
  update public.invites set uses = uses + 1 where token = i.token;
  select private.short_name(name) into v_name from public.profiles where id = uid;
  select name into v_room from public.rooms where id = i.room_id;
  insert into public.messages (room_id, text, sys) values (i.room_id, v_name || ' joined via invite link 👋', true);
  insert into public.notifications (user_id, room_id, text)
    select m.user_id, i.room_id, v_name || ' joined ' || v_room from public.room_members m where m.room_id = i.room_id and m.is_admin;
  return i.room_id;
end $$;

-- Everything that moves shifts between people or puts someone on a shift takes the same room lock first, before the
-- offer or request rows, so it can't interleave with someone leaving or being removed (a swap could hand a shift to
-- someone on their way out, past leave_room's check for upcoming shifts) and all of them lock rows in one order (no
-- deadlocks between a swap and a removal).

-- swaps: as in 20261010000000, with the room lock first
create or replace function public.apply_swap(p_offer bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  o public.offers; r public.requests; c jsonb; n int;
  v_sid uuid; v_out uuid; v_in uuid; v_owner text; v_taker text; v_date text; v_msg text;
begin
  perform 1 from public.rooms
    where id = (select q.room_id from public.offers x join public.requests q on q.id = x.request_id where x.id = p_offer)
    for no key update;
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

  -- shifts that have started are history: they can't change hands
  if exists (select 1 from public.shifts s where s.starts_at <= now()
             and s.id in (select (x ->> 'sid')::uuid from jsonb_array_elements(o.changes) x)) then
    raise exception 'This shift already started.';
  end if;

  for c in select * from jsonb_array_elements(o.changes) loop
    v_sid := (c ->> 'sid')::uuid; v_out := (c ->> 'out')::uuid; v_in := (c ->> 'in')::uuid;
    if not exists (select 1 from public.shift_members where shift_id = v_sid and room_id = r.room_id and user_id = v_out)
       or exists (select 1 from public.shift_members where shift_id = v_sid and user_id = v_in) then
      raise exception 'That offer is no longer possible.';
    end if;
  end loop;

  -- the room's rules: the swap can't add a violation
  select x.msg into v_msg from private.new_violations(r.room_id, o.changes) x limit 1;
  if v_msg is not null then raise exception 'That swap breaks a rule. %', v_msg; end if;

  for c in select * from jsonb_array_elements(o.changes) loop
    update public.shift_members set user_id = (c ->> 'in')::uuid
      where shift_id = (c ->> 'sid')::uuid and user_id = (c ->> 'out')::uuid;
  end loop;

  update public.requests set status = 'done', taker_id = o.from_id where id = r.id;
  update public.offers set status = 'accepted' where id = o.id;
  update public.offers set status = 'void' where request_id = r.id and status = 'pending';
  update public.requests set status = 'void'
    where id <> r.id and status in ('open', 'waiting')
      and shift_id in (select (x ->> 'sid')::uuid from jsonb_array_elements(o.changes) x);

  select private.short_name(name) into v_owner from public.profiles where id = r.owner_id;
  select private.short_name(name) into v_taker from public.profiles where id = o.from_id;
  select to_char(s.starts_at at time zone ro.tz, 'Dy FMDD Mon') into v_date
    from public.shifts s join public.rooms ro on ro.id = s.room_id where s.id = r.shift_id;
  insert into public.messages (room_id, text, sys) values (r.room_id,
    format('%s''s %s shift now goes to %s%s ✓', v_owner, v_date, v_taker, case when r.sell then ' · €' || r.price else '' end), true);
end $$;

-- the owner accepts an offer in a room that needs admin approval: as in 20261009000000, with the room lock first
create or replace function public.request_approval(p_offer bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare o public.offers; r public.requests;
begin
  perform 1 from public.rooms where id = (select x.room_id from public.offers x where x.id = p_offer) for no key update;
  select * into o from public.offers where id = p_offer for update;
  if not found or o.status <> 'pending' then raise exception 'This offer is no longer available.'; end if;
  select * into r from public.requests where id = o.request_id for update;
  if r.owner_id <> auth.uid() then raise exception 'Not allowed'; end if;
  if r.status <> 'open' then raise exception 'This request is no longer open.'; end if;
  if not (select approval_mode from public.rooms where id = r.room_id) then raise exception 'Not allowed'; end if;
  if not private.shift_open(r.shift_id) then raise exception 'This shift already started.'; end if;
  update public.requests set status = 'waiting', taker_id = o.from_id, accepted_offer = o.id where id = r.id;
end $$;

-- an admin declines a swap waiting for approval: as in 20261001000000, with the room lock first
create or replace function public.decline_swap(p_request bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.requests;
begin
  perform 1 from public.rooms where id = (select q.room_id from public.requests q where q.id = p_request) for no key update;
  select * into r from public.requests where id = p_request for update;
  if not found or not private.is_admin(r.room_id) then raise exception 'Not allowed'; end if;
  if r.status <> 'waiting' then raise exception 'This request is no longer open.'; end if;
  update public.offers set status = 'declined' where id = r.accepted_offer and status = 'pending';
  update public.requests set status = 'open', taker_id = null, accepted_offer = null where id = r.id;
end $$;

-- someone joining a shift (or an admin assigning them) waits for a leave or removal in progress, then must still be a
-- member (the insert's own policy check ran before the wait, so it can't see the removal)
create function private.lock_room_for_shift_member() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform 1 from public.rooms where id = new.room_id for no key update;
  if not exists (select 1 from public.room_members where room_id = new.room_id and user_id = new.user_id) then
    raise exception 'Not allowed';
  end if;
  return new;
end $$;
revoke all on function private.lock_room_for_shift_member() from public, anon, authenticated;
create trigger shift_members_lock_room before insert on public.shift_members
  for each row execute function private.lock_room_for_shift_member();

revoke all on function public.leave_room(uuid) from public, anon;
revoke all on function public.remove_member(uuid, uuid) from public, anon;
grant execute on function public.leave_room(uuid) to authenticated;
grant execute on function public.remove_member(uuid, uuid) to authenticated;

-- ---------- 3. usage events ----------

-- props: only the keys the app sends, each with its type; strings are short codes or a room id, never free text
create function private.event_props_ok(p jsonb) returns boolean
language sql immutable set search_path = '' as $$
  select jsonb_typeof(p) = 'object' and not exists (
    select 1 from jsonb_each(p) e
    where not case
      when jsonb_typeof(e.value) = 'null' then e.key in ('kind', 'where', 'to', 'via', 'k', 'type', 'lang', 'method', 'room',
        'sell', 'urgent', 'swap', 'approved', 'admin', 'self', 'rid', 'notified', 'shifts', 'hours')
      when e.key in ('kind', 'where', 'to', 'via', 'k', 'type', 'lang', 'method') then
        jsonb_typeof(e.value) = 'string' and e.value #>> '{}' ~ '^[a-z0-9_]{1,24}$'
      when e.key = 'room' then
        jsonb_typeof(e.value) = 'string' and e.value #>> '{}' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      when e.key in ('sell', 'urgent', 'swap', 'approved', 'admin', 'self') then jsonb_typeof(e.value) = 'boolean'
      when e.key in ('rid', 'notified', 'shifts', 'hours') then
        case when jsonb_typeof(e.value) = 'number' then abs((e.value #>> '{}')::numeric) < 1e12 else false end
      else false end)
$$;

-- the events the app records (sign-ups are recorded by the database itself, never by the app)
create function private.event_ok(n text, p jsonb) returns boolean
language sql immutable set search_path = '' as $$
  select n in ('admin_approved', 'admin_declined', 'blocked', 'csv_import', 'invite_created', 'invite_joined',
               'language_changed', 'logout', 'member_removed', 'message', 'notification', 'offer_declined', 'offer_sent',
               'owner_added', 'password_changed', 'profile_edited', 'reaction', 'report_created', 'request_cancelled',
               'request_posted', 'room_created', 'room_deleted', 'room_left', 'rule_created', 'session', 'shift_added',
               'swap_completed', 'thread_reply')
    and private.event_props_ok(p)
$$;
revoke all on function private.event_props_ok(jsonb) from public, anon;
revoke all on function private.event_ok(text, jsonb) from public, anon;
grant execute on function private.event_props_ok(jsonb) to authenticated;
grant execute on function private.event_ok(text, jsonb) to authenticated;

drop policy "people record their own usage" on public.app_events;
create policy "people record their own usage" on public.app_events for insert to authenticated
  with check (user_id = (select auth.uid()) and (room_id is null or private.is_member(room_id)) and private.event_ok(name, props));

-- events already stored with other props keep their count, not their props
update public.app_events set props = '{}' where not private.event_props_ok(props);
