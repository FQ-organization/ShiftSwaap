-- A swap reads as a swap. The two people are told what they gave and what they now work ("Swap done: you gave Tue 6 Oct
-- and now work Wed 7 Oct"), and the feed says who takes which day. Taking a shift as is, or buying it, reads as before.
-- Whoever completes the swap isn't notified about their own action (the owner accepting, in a room without approval).
-- apply_swap is as in 20261014000000 otherwise.

create or replace function public.apply_swap(p_offer bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  o public.offers; r public.requests; c jsonb; n int;
  v_sid uuid; v_out uuid; v_in uuid; v_owner text; v_taker text; v_date text; v_date2 text; v_msg text;
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
  if n = 2 then
    select to_char(s.starts_at at time zone ro.tz, 'Dy FMDD Mon') into v_date2
      from public.shifts s join public.rooms ro on ro.id = s.room_id where s.id = (o.changes -> 1 ->> 'sid')::uuid;
  end if;
  insert into public.notifications (user_id, room_id, text, sub, dedupe)
    select u, r.room_id, t, null, 'done:' || r.id from (values
      (r.owner_id, case when n = 2 then format('Swap done: you gave %s and now work %s', v_date, v_date2)
                        else format('%s took your shift%s', v_taker, case when r.sell then ' · €' || r.price else '' end) end),
      (o.from_id, case when n = 2 then format('Swap done: you gave %s and now work %s', v_date2, v_date)
                       else 'Your new shift is confirmed' end)) x (u, t)
    where u is distinct from uid
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
    case when n = 2 then format('Swap: %s takes %s and %s takes %s ✓', v_taker, v_date, v_owner, v_date2)
         else format('%s''s %s shift now goes to %s%s ✓', v_owner, v_date, v_taker, case when r.sell then ' · €' || r.price else '' end) end, true);
end $$;
