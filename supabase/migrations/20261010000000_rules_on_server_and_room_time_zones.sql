-- 1. Every room has a time zone. Shift days, "today", weeks and months for the rules, and report months all
--    follow the room's clock instead of UTC.
-- 2. The database enforces the room's rules: a swap (apply_swap) and a member joining a shift can't create a
--    rule violation that wasn't already there. Same test as the app: compare the violations before and after.

-- ---------- time zones ----------

create function private.valid_tz(t text) returns boolean
language plpgsql immutable set search_path = '' as $$
begin
  if t is null or t = '' then return false; end if;
  perform now() at time zone t;
  return true;
exception when others then return false;
end $$;

alter table public.rooms add column tz text not null default 'UTC' check (private.valid_tz(tz));

-- the existing rooms are Portuguese teams
update public.rooms set tz = 'Europe/Lisbon';

-- shifts used to be stored at 08:00 UTC; the ones that haven't started now start at 08:00 Lisbon time
update public.shifts s
  set starts_at = ((s.starts_at at time zone 'UTC')::date + time '08:00') at time zone 'Europe/Lisbon',
      ends_at = ((s.starts_at at time zone 'UTC')::date + 1 + time '08:00') at time zone 'Europe/Lisbon'
  where s.starts_at > now()
    and to_char(s.starts_at at time zone 'UTC', 'HH24:MI') = '08:00'
    and s.ends_at - s.starts_at = interval '24 hours';

-- new rooms take the creator's time zone
create function public.create_room(p_id uuid, p_name text, p_icon text, p_bg text, p_type text, p_tz text)
returns uuid language plpgsql security definer set search_path = '' as $$
begin
  perform public.create_room(p_id, p_name, p_icon, p_bg, p_type);
  update public.rooms set tz = case when private.valid_tz(p_tz) then p_tz else 'UTC' end where id = p_id;
  return p_id;
end $$;
revoke all on function public.create_room(uuid, text, text, text, text, text) from public, anon;
grant execute on function public.create_room(uuid, text, text, text, text, text) to authenticated;

-- changing the zone keeps each upcoming shift on the same date and wall-clock time
create function public.set_room_tz(p_room uuid, p_tz text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_old text;
begin
  if not private.is_admin(p_room) then raise exception 'Not allowed'; end if;
  if not private.valid_tz(p_tz) then raise exception 'Unknown time zone.'; end if;
  select tz into v_old from public.rooms where id = p_room for update;
  if v_old = p_tz then return; end if;
  update public.shifts
    set starts_at = (starts_at at time zone v_old) at time zone p_tz,
        ends_at = (ends_at at time zone v_old) at time zone p_tz
    where room_id = p_room and starts_at > now() and (starts_at at time zone v_old) at time zone p_tz > now();
  update public.rooms set tz = p_tz where id = p_room;
end $$;
revoke all on function public.set_room_tz(uuid, text) from public, anon;
grant execute on function public.set_room_tz(uuid, text) to authenticated;

-- ---------- rules ----------
-- Every violation of the room's enabled rules, with p_changes applied first ([{sid, out, in}], as in offers).
-- k identifies a violation, so "new" violations are the keys that weren't there before the change.
--   shift:   a shift's staffing condition (at least / at most / exactly n people with any of the tags)
--   overlap: one person on two overlapping shifts
--   rest:    fewer hours than the rule between one person's shifts
--   max:     more shifts than the rule in one week (Monday to Sunday) or month, in the room's time zone

create function private.rule_violations(p_room uuid, p_changes jsonb default '[]')
returns table (k text, kind text, user_id uuid, msg text)
language sql stable security definer set search_path = '' as $$
  with
  ch as (select (x ->> 'sid')::uuid sid, (x ->> 'out')::uuid u_out, (x ->> 'in')::uuid u_in
         from jsonb_array_elements(coalesce(p_changes, '[]'::jsonb)) x),
  rm as (select tz from public.rooms where id = p_room),
  sh as (select s.id, s.starts_at, s.ends_at, to_char(s.starts_at at time zone (select tz from rm), 'Dy FMDD Mon') d
         from public.shifts s where s.room_id = p_room),
  asg as (
    select m.shift_id, m.user_id from public.shift_members m
    where m.room_id = p_room and not exists (select 1 from ch where ch.sid = m.shift_id and ch.u_out = m.user_id)
    union
    select ch.sid, ch.u_in from ch join sh on sh.id = ch.sid where ch.u_in is not null),
  ru as (select r.id, r.name, r.type, r.conds, r.h, r.n, r.per, r.tags
         from public.room_rules r where r.room_id = p_room and r.enabled),
  tagged as (select mt.user_id, mt.tag_id from public.member_tags mt where mt.room_id = p_room),
  people as (select u.user_id, private.short_name(p.name) nm
             from (select distinct a.user_id from asg a) u left join public.profiles p on p.id = u.user_id),
  cn as (select ru.id rid, ru.name rname, c.ord, c.v ->> 'op' op, (c.v ->> 'n')::int n,
           coalesce((select array_agg(t::uuid) from jsonb_array_elements_text(c.v -> 'tags') t), '{}') tags,
           coalesce((select string_agg(rt.name, ' or ' order by rt.name) from public.room_tags rt
                     where rt.room_id = p_room and rt.id::text in (select jsonb_array_elements_text(c.v -> 'tags'))), 'people') who
         from ru cross join lateral jsonb_array_elements(ru.conds) with ordinality c(v, ord) where ru.type = 'shift'),
  staffing as (
    select cn.*, sh.id sid, sh.d,
      (select count(*) from asg a where a.shift_id = sh.id
         and (cardinality(cn.tags) = 0
              or exists (select 1 from tagged t where t.user_id = a.user_id and t.tag_id = any(cn.tags)))) have
    from cn cross join sh),
  mine as (
    select a.user_id, sh.id sid, sh.d, sh.starts_at, lag(sh.ends_at) over w prev_end, lag(sh.d) over w prev_d
    from asg a join sh on sh.id = a.shift_id
    window w as (partition by a.user_id order by sh.starts_at)),
  gaps as (select mine.*, extract(epoch from starts_at - prev_end) / 3600.0 g from mine where prev_end is not null),
  applies as (
    select ru.id rid, pp.user_id from ru cross join people pp
    where ru.type in ('rest', 'max')
      and (cardinality(ru.tags) = 0
           or exists (select 1 from tagged t where t.user_id = pp.user_id and t.tag_id = any(ru.tags)))),
  buckets as (
    select ru.id rid, ru.name rname, ru.n, ru.per, a.user_id,
      date_trunc(ru.per, sh.starts_at at time zone (select tz from rm)) b, count(*) cnt
    from ru join applies ap on ap.rid = ru.id join asg a on a.user_id = ap.user_id join sh on sh.id = a.shift_id
    where ru.type = 'max'
    group by ru.id, ru.name, ru.n, ru.per, a.user_id, 6)
  select 'shift:' || s.rid || ':' || s.sid || ':' || s.ord, 'shift', null::uuid,
    format('%s: %s would have %s %s, but needs %s %s.', s.rname, s.d, s.have, s.who,
           case s.op when 'min' then 'at least' when 'max' then 'at most' else 'exactly' end, s.n)
  from staffing s where (s.op = 'min' and s.have < s.n) or (s.op = 'max' and s.have > s.n) or (s.op = 'eq' and s.have <> s.n)
  union all
  select 'overlap:' || g.user_id || ':' || g.sid, 'overlap', g.user_id,
    format('%s would work overlapping shifts on %s and %s.', pp.nm, g.prev_d, g.d)
  from gaps g join people pp on pp.user_id = g.user_id where g.g < 0
  union all
  select 'rest:' || ru.id || ':' || g.user_id || ':' || g.sid, 'rest', g.user_id,
    format('%s: %s would have only %sh of rest between %s and %s (minimum %sh).', ru.name, pp.nm, floor(g.g), g.prev_d, g.d, ru.h)
  from gaps g join ru on ru.type = 'rest' join applies ap on ap.rid = ru.id and ap.user_id = g.user_id
    join people pp on pp.user_id = g.user_id
  where g.g >= 0 and g.g < ru.h
  union all
  select 'max:' || b.rid || ':' || b.user_id || ':' || b.b, 'max', b.user_id,
    format('%s: %s would work %s shifts in one %s (maximum %s).', b.rname, pp.nm, b.cnt, b.per, b.n)
  from buckets b join people pp on pp.user_id = b.user_id where b.cnt > b.n
$$;
revoke all on function private.rule_violations(uuid, jsonb) from public, anon;

-- the violations a change would add
create function private.new_violations(p_room uuid, p_changes jsonb)
returns table (k text, kind text, user_id uuid, msg text)
language sql stable security definer set search_path = '' as $$
  select a.* from private.rule_violations(p_room, p_changes) a
  where a.k not in (select b.k from private.rule_violations(p_room, '[]') b)
$$;
revoke all on function private.new_violations(uuid, jsonb) from public, anon;

-- a member who adds themselves to a shift can't break their own rest, maximum or overlap rules
-- (admins can still assign anyone: the app asks them to confirm an override)
create function private.check_join() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_msg text;
begin
  if auth.uid() is null or private.is_admin(new.room_id) then return null; end if;
  select a.msg into v_msg from private.rule_violations(new.room_id, '[]') a
  where a.user_id = new.user_id and a.kind in ('overlap', 'rest', 'max')
    and a.k not in (select b.k from private.rule_violations(new.room_id,
                      jsonb_build_array(jsonb_build_object('sid', new.shift_id, 'out', new.user_id))) b)
  limit 1;
  if v_msg is not null then raise exception 'That breaks a rule. %', v_msg; end if;
  return null;
end $$;
create trigger shift_members_follow_rules after insert on public.shift_members
  for each row execute function private.check_join();

-- swaps: same checks as before, plus the rules, and the feed line uses the room's date
create or replace function public.apply_swap(p_offer bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  o public.offers; r public.requests; c jsonb; n int;
  v_sid uuid; v_out uuid; v_in uuid; v_owner text; v_taker text; v_date text; v_msg text;
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

-- reports: a month is the room's calendar month
create or replace function public.room_report(p_room uuid, p_month date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_tz text := coalesce((select tz from public.rooms where id = p_room), 'UTC');
  m0 timestamptz := date_trunc('month', p_month)::timestamp at time zone v_tz;
  m1 timestamptz := (date_trunc('month', p_month) + interval '1 month')::timestamp at time zone v_tz;
  result jsonb;
begin
  if not private.is_admin(p_room) then raise exception 'Not allowed'; end if;

  with sh as (
    select id, extract(epoch from ends_at - starts_at) / 3600.0 as hrs
    from public.shifts where room_id = p_room and starts_at >= m0 and starts_at < m1),
  seats as (
    select m.user_id, s.hrs from sh s join public.shift_members m on m.shift_id = s.id),
  rq as (
    select r.owner_id, r.taker_id, r.status, r.sell, r.price,
      (select jsonb_array_length(o.changes) from public.offers o where o.request_id = r.id and o.status = 'accepted' limit 1) as nchg
    from public.requests r join sh on sh.id = r.shift_id),
  ppl as (
    select user_id from seats
    union select owner_id from rq
    union select taker_id from rq where status = 'done' and taker_id is not null)
  select jsonb_build_object(
    'month', to_char(m0 at time zone v_tz, 'YYYY-MM'),
    'shifts', (select count(*) from sh),
    'seats', (select count(*) from seats),
    'hours', (select coalesce(round(sum(hrs)::numeric, 1), 0) from seats),
    'requests', (select count(*) from rq),
    'swaps', (select count(*) from rq where status = 'done' and not sell and nchg = 2),
    'given', (select count(*) from rq where status = 'done' and not sell and coalesce(nchg, 1) <> 2),
    'sales', (select count(*) from rq where status = 'done' and sell),
    'sales_total', (select coalesce(sum(price), 0) from rq where status = 'done' and sell),
    'open', (select count(*) from rq where status in ('open', 'waiting')),
    'cancelled', (select count(*) from rq where status = 'void'),
    'people', (select coalesce(jsonb_agg(t.x order by t.x ->> 'name'), '[]'::jsonb) from (
      select jsonb_build_object(
        'user_id', p.user_id,
        'name', coalesce(pr.name, '?'),
        'shifts', (select count(*) from seats where user_id = p.user_id),
        'hours', (select coalesce(round(sum(hrs)::numeric, 1), 0) from seats where user_id = p.user_id),
        'asked', (select count(*) from rq where owner_id = p.user_id),
        'gave', (select count(*) from rq where owner_id = p.user_id and status = 'done' and not sell),
        'took', (select count(*) from rq where taker_id = p.user_id and status = 'done' and not sell),
        'sold', (select count(*) from rq where owner_id = p.user_id and status = 'done' and sell),
        'bought', (select count(*) from rq where taker_id = p.user_id and status = 'done' and sell),
        'earned', (select coalesce(sum(price), 0) from rq where owner_id = p.user_id and status = 'done' and sell),
        'spent', (select coalesce(sum(price), 0) from rq where taker_id = p.user_id and status = 'done' and sell)) as x
      from ppl p left join public.profiles pr on pr.id = p.user_id
      where p.user_id is not null) t))
  into result;
  return result;
end $$;
