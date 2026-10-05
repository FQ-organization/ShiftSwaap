-- The rules refuse a change that makes a violation worse, not only one that adds a new violation. Before, once a
-- rule was broken it stopped limiting anything: someone already over "at most 5 a month" could keep taking shifts,
-- and a shift short of seniors could lose its last one. Same test as the app: each violation has a severity (sev),
-- and a change is refused if it adds a violation or raises the severity of one that was already there.
--   shift:   how far the count is from the condition (people missing, or people too many)
--   overlap: hours of overlap
--   rest:    hours of rest missing
--   max:     shifts over the maximum
-- Changes that keep or reduce violations are still allowed, so a schedule that already breaks a rule doesn't freeze.

-- rule_violations_sev is rule_violations plus sev. It is a new function, so nothing is dropped; new_violations and
-- check_join switch to it, and the old rule_violations stays in place, unused.
create or replace function private.rule_violations_sev(p_room uuid, p_changes jsonb default '[]')
returns table (k text, kind text, user_id uuid, msg text, sev numeric)
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
           case s.op when 'min' then 'at least' when 'max' then 'at most' else 'exactly' end, s.n),
    abs(s.have - s.n)::numeric
  from staffing s where (s.op = 'min' and s.have < s.n) or (s.op = 'max' and s.have > s.n) or (s.op = 'eq' and s.have <> s.n)
  union all
  select 'overlap:' || g.user_id || ':' || g.sid, 'overlap', g.user_id,
    format('%s would work overlapping shifts on %s and %s.', pp.nm, g.prev_d, g.d), -g.g
  from gaps g join people pp on pp.user_id = g.user_id where g.g < 0
  union all
  select 'rest:' || ru.id || ':' || g.user_id || ':' || g.sid, 'rest', g.user_id,
    format('%s: %s would have only %sh of rest between %s and %s (minimum %sh).', ru.name, pp.nm, floor(g.g), g.prev_d, g.d, ru.h),
    ru.h - g.g
  from gaps g join ru on ru.type = 'rest' join applies ap on ap.rid = ru.id and ap.user_id = g.user_id
    join people pp on pp.user_id = g.user_id
  where g.g >= 0 and g.g < ru.h
  union all
  select 'max:' || b.rid || ':' || b.user_id || ':' || b.b, 'max', b.user_id,
    format('%s: %s would work %s shifts in one %s (maximum %s).', b.rname, pp.nm, b.cnt, b.per, b.n), (b.cnt - b.n)::numeric
  from buckets b join people pp on pp.user_id = b.user_id where b.cnt > b.n
$$;
revoke all on function private.rule_violations_sev(uuid, jsonb) from public, anon;

-- the violations a change would add or make worse
create or replace function private.new_violations(p_room uuid, p_changes jsonb)
returns table (k text, kind text, user_id uuid, msg text)
language sql stable security definer set search_path = '' as $$
  with b as materialized (select v.k, v.sev from private.rule_violations_sev(p_room, '[]') v)
  select a.k, a.kind, a.user_id, a.msg from private.rule_violations_sev(p_room, p_changes) a
  left join b on b.k = a.k
  where b.k is null or a.sev > b.sev
$$;

-- a member who adds themselves to a shift can't add a violation or make one worse: their own rest, maximum or overlap,
-- or the shift's "at most" / "exactly" conditions. Joining never makes a shift's shortfall worse, so a shift that is
-- still waiting for teammates can be joined. Admins can still assign anyone: the app asks them to confirm an override.
create or replace function private.check_join() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_msg text;
begin
  if auth.uid() is null or private.is_admin(new.room_id) then return null; end if;
  select a.msg into v_msg from private.rule_violations_sev(new.room_id, '[]') a
    left join private.rule_violations_sev(new.room_id,
                jsonb_build_array(jsonb_build_object('sid', new.shift_id, 'out', new.user_id))) b on b.k = a.k
  where b.k is null or a.sev > b.sev
  limit 1;
  if v_msg is not null then raise exception 'That breaks a rule. %', v_msg; end if;
  return null;
end $$;
