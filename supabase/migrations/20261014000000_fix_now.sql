-- Fixes from the 20-reviewer audit ("Fix now"):
-- 1. Leaving a shift goes through leave_shift(), with the same checks as the app: only a shift still waiting for
--    teammates, not started, and without breaking a rule (deepening the headcount it already lacks is allowed).
--    Members can no longer delete their own shift_members row directly; admins still can.
-- 2. A completed swap only closes the requests of the people it moves off a shift. A co-worker's request on the same
--    shift stays open (it used to be closed with its offers).
-- 3. Selling: a room with selling turned off refuses new sale requests and refuses to complete one already open.
-- 4. Admins edit only the room columns the app edits. tz (set_room_tz) and deleted_at (delete_room) only change through
--    their functions, which keep shifts and invite links consistent. Invite links of a deleted room stop working.
-- 5. Usage events accept client_error (a count of app errors, with the error's type only).
--
-- Safe to run more than once (policies are created only if missing, everything else is create or replace / grant).
-- Parts 2, 3 and 5 are already applied on dev; the whole file still needs to run on prod, and parts 1 and 4 on dev.

-- ---------- 1. leaving a shift ----------

do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'shift_members'
                 and policyname = 'people leave shifts through leave_shift') then
    create policy "people leave shifts through leave_shift" on public.shift_members as restrictive for delete to authenticated
      using (private.is_admin(room_id));
  end if;
end $$;

create or replace function public.leave_shift(p_shift uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); s public.shifts; v_msg text;
begin
  select * into s from public.shifts where id = p_shift;
  if not found then raise exception 'Not allowed'; end if;
  perform 1 from public.rooms where id = s.room_id for no key update;
  if not private.is_member(s.room_id) then raise exception 'Not allowed'; end if;
  if not exists (select 1 from public.shift_members where shift_id = p_shift and user_id = uid) then
    raise exception 'You are not on this shift.';
  end if;
  if s.starts_at <= now() then raise exception 'This shift already started.'; end if;
  -- only a shift still waiting for teammates: some "at least" / "exactly" condition isn't met yet
  if not exists (
    select 1 from public.room_rules ru cross join lateral jsonb_array_elements(ru.conds) c(v)
    where ru.room_id = s.room_id and ru.enabled and ru.type = 'shift' and c.v ->> 'op' <> 'max'
      and (c.v ->> 'n')::int > (
        select count(*) from public.shift_members m
        where m.shift_id = p_shift
          and (jsonb_array_length(coalesce(c.v -> 'tags', '[]'::jsonb)) = 0
               or exists (select 1 from public.member_tags t where t.room_id = s.room_id and t.user_id = m.user_id
                            and t.tag_id::text in (select jsonb_array_elements_text(c.v -> 'tags')))))) then
    raise exception 'This shift is complete. Ask for a swap instead.';
  end if;
  -- no new or worse violation, except a headcount shortfall the shift already had
  select a.msg into v_msg
  from private.rule_violations_sev(s.room_id, jsonb_build_array(jsonb_build_object('sid', p_shift, 'out', uid))) a
  left join private.rule_violations_sev(s.room_id, '[]') b on b.k = a.k
  where (b.k is null or a.sev > b.sev)
    and not (b.k is not null and a.kind = 'shift' and exists (
      select 1 from public.room_rules ru cross join lateral jsonb_array_elements(ru.conds) with ordinality c(v, ord)
      where ru.room_id = s.room_id and a.k = 'shift:' || ru.id || ':' || p_shift || ':' || c.ord
        and c.v ->> 'op' in ('min', 'eq') and jsonb_array_length(coalesce(c.v -> 'tags', '[]'::jsonb)) = 0))
  limit 1;
  if v_msg is not null then raise exception 'That breaks a rule. %', v_msg; end if;

  update public.requests set status = 'void' where shift_id = p_shift and owner_id = uid and status in ('open', 'waiting');
  delete from public.shift_members where shift_id = p_shift and user_id = uid;
  delete from public.shifts where id = p_shift and not exists (select 1 from public.shift_members where shift_id = p_shift);
end $$;
revoke all on function public.leave_shift(uuid) from public, anon;
grant execute on function public.leave_shift(uuid) to authenticated;

-- ---------- 2 and 3. swaps: as in 20261013000000, closing only the requests of the people who move, and no sales
-- when selling is off ----------

create or replace function public.apply_swap(p_offer bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  o public.offers; r public.requests; c jsonb; n int;
  v_sid uuid; v_out uuid; v_in uuid; v_owner text; v_taker text; v_date text; v_msg text;
begin
  select * into o from public.offers where id = p_offer;
  perform 1 from public.rooms where id = (select q.room_id from public.requests q where q.id = o.request_id) for no key update;
  select * into r from public.requests where id = o.request_id for update;
  -- the other requests for the shifts this swap moves (closed below)
  perform 1 from public.requests q
    where q.id <> o.request_id and q.status in ('open', 'waiting')
      and q.shift_id in (select (x ->> 'sid')::uuid from jsonb_array_elements(case when jsonb_typeof(o.changes) = 'array' then o.changes else '[]' end) x)
    order by q.id for update;
  select * into o from public.offers where id = p_offer for update;
  if not found or o.status <> 'pending' then raise exception 'This offer is no longer available.'; end if;

  if r.status = 'open' then
    if r.owner_id <> uid then raise exception 'Not allowed'; end if;
    if (select approval_mode from public.rooms where id = r.room_id) then raise exception 'Not allowed'; end if;
  elsif r.status = 'waiting' then
    if r.accepted_offer is distinct from o.id or not private.is_admin(r.room_id) then raise exception 'Not allowed'; end if;
    if not private.can_decide(r.room_id, r.owner_id, r.taker_id) then
      raise exception 'Another admin has to approve a swap you are part of.';
    end if;
  else
    raise exception 'This request is no longer open.';
  end if;
  if r.sell and not (select allow_sell from public.rooms where id = r.room_id) then
    raise exception 'Selling shifts is turned off in this room.';
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

  -- who is told, read before the updates below close the other offers and requests
  select private.short_name(name) into v_owner from public.profiles where id = r.owner_id;
  select private.short_name(name) into v_taker from public.profiles where id = o.from_id;
  select to_char(s.starts_at at time zone ro.tz, 'Dy FMDD Mon') into v_date
    from public.shifts s join public.rooms ro on ro.id = s.room_id where s.id = r.shift_id;
  insert into public.notifications (user_id, room_id, text, sub, dedupe)
    select u, r.room_id, t, null, 'done:' || r.id from (values
      (r.owner_id, format('%s took your shift%s', v_taker, case when r.sell then ' · €' || r.price else '' end)),
      (o.from_id, 'Your new shift is confirmed')) x (u, t)
    union all
    select distinct x.from_id, r.room_id, 'Another offer was accepted for ' || v_date, null, 'done:' || r.id
      from public.offers x where x.request_id = r.id and x.status = 'pending' and x.from_id <> o.from_id
    union all
    select q.owner_id, q.room_id, format('Your request for %s was closed', to_char(s.starts_at at time zone ro.tz, 'Dy FMDD Mon')),
           'That shift changed hands in another swap.', 'closed:' || q.id
      from public.requests q join public.shifts s on s.id = q.shift_id join public.rooms ro on ro.id = q.room_id
      where q.id <> r.id and q.status in ('open', 'waiting')
        and exists (select 1 from jsonb_array_elements(o.changes) x
                    where (x ->> 'sid')::uuid = q.shift_id and (x ->> 'out')::uuid = q.owner_id)
    union all
    select distinct f.from_id, q.room_id,
           format('%s''s request for %s was closed', private.short_name(p.name), to_char(s.starts_at at time zone ro.tz, 'Dy FMDD Mon')),
           'Your offer is closed.', 'closed:' || q.id
      from public.requests q join public.shifts s on s.id = q.shift_id join public.rooms ro on ro.id = q.room_id
        join public.profiles p on p.id = q.owner_id join public.offers f on f.request_id = q.id and f.status = 'pending'
      where q.id <> r.id and q.status in ('open', 'waiting')
        and exists (select 1 from jsonb_array_elements(o.changes) x
                    where (x ->> 'sid')::uuid = q.shift_id and (x ->> 'out')::uuid = q.owner_id)
  on conflict (user_id, dedupe) do nothing;

  -- (the requests_close_offers trigger voids the other offers of every request closed here)
  update public.requests set status = 'done', taker_id = o.from_id where id = r.id;
  update public.offers set status = 'accepted' where id = o.id;
  update public.offers set status = 'void' where request_id = r.id and status = 'pending';
  update public.requests q set status = 'void'
    where q.id <> r.id and q.status in ('open', 'waiting')
      and exists (select 1 from jsonb_array_elements(o.changes) x
                  where (x ->> 'sid')::uuid = q.shift_id and (x ->> 'out')::uuid = q.owner_id);

  insert into public.messages (room_id, text, sys) values (r.room_id,
    format('%s''s %s shift now goes to %s%s ✓', v_owner, v_date, v_taker, case when r.sell then ' · €' || r.price else '' end), true);
end $$;

do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'requests'
                 and policyname = 'sales only where selling is allowed') then
    create policy "sales only where selling is allowed" on public.requests as restrictive for insert to authenticated
      with check (not sell or exists (select 1 from public.rooms ro where ro.id = room_id and ro.allow_sell));
  end if;
end $$;

-- ---------- 4. room columns and deleted rooms ----------

revoke update on public.rooms from authenticated;
grant update (name, icon, bg, shift_type, allow_sell, approval_mode) on public.rooms to authenticated;

-- invite links: as in 20261012000000, and a deleted room's links stop working
create or replace function public.invite_preview(p_token text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare i public.invites; r public.rooms;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select * into i from public.invites where token = lower(p_token);
  if not found then return jsonb_build_object('status', 'invalid'); end if;
  if i.revoked then return jsonb_build_object('status', 'revoked'); end if;
  if i.expires_at < now() then return jsonb_build_object('status', 'expired'); end if;
  if exists (select 1 from public.rooms where id = i.room_id and deleted_at is not null) then
    return jsonb_build_object('status', 'invalid');
  end if;
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
  if i.revoked or i.expires_at < now()
     or exists (select 1 from public.rooms where id = i.room_id and deleted_at is not null) then
    raise exception 'This link is no longer valid.';
  end if;
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

-- ---------- 5. usage events: as in 20261012000000, plus client_error ----------

create or replace function private.event_ok(n text, p jsonb) returns boolean
language sql immutable set search_path = '' as $$
  select n in ('admin_approved', 'admin_declined', 'blocked', 'csv_import', 'invite_created', 'invite_joined',
               'language_changed', 'logout', 'member_removed', 'message', 'notification', 'offer_declined', 'offer_sent',
               'owner_added', 'password_changed', 'profile_edited', 'reaction', 'report_created', 'request_cancelled',
               'request_posted', 'room_created', 'room_deleted', 'room_left', 'rule_created', 'session', 'shift_added',
               'swap_completed', 'thread_reply', 'client_error')
    and private.event_props_ok(p)
$$;
