-- Names show as first name + last initial ("Francisco Quinaz Gomes" -> "Francisco G."), so they fit on one line.
-- The app shortens names itself; this does the same for the texts the database writes (feed system lines, notifications).

create function private.short_name(n text) returns text
language sql immutable set search_path = '' as $$
  select case
    when trim(coalesce(n, '')) = '' then '?'
    when array_length(p, 1) = 1 then p[1]
    else p[1] || ' ' || upper(left(p[array_length(p, 1)], 1)) || '.'
  end
  from (select regexp_split_to_array(trim(n), '\s+') as p) x
$$;
revoke all on function private.short_name(text) from public, anon;

create or replace function public.join_room(p_token text) returns uuid
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
  select private.short_name(name) into v_name from public.profiles where id = uid;
  select name into v_room from public.rooms where id = i.room_id;
  insert into public.messages (room_id, text, sys) values (i.room_id, v_name || ' joined via invite link 👋', true);
  insert into public.notifications (user_id, room_id, text)
    select m.user_id, i.room_id, v_name || ' joined ' || v_room from public.room_members m where m.room_id = i.room_id and m.is_admin;
  return i.room_id;
end $$;

create or replace function public.apply_swap(p_offer bigint) returns void
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

  select private.short_name(name) into v_owner from public.profiles where id = r.owner_id;
  select private.short_name(name) into v_taker from public.profiles where id = o.from_id;
  select to_char(starts_at at time zone 'UTC', 'Dy FMDD Mon') into v_date from public.shifts where id = r.shift_id;
  insert into public.messages (room_id, text, sys) values (r.room_id,
    format('%s''s %s shift now goes to %s%s ✓', v_owner, v_date, v_taker, case when r.sell then ' · €' || r.price else '' end), true);
end $$;
