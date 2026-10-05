-- Fixes for the Medium-severity QA findings. Each group of fixes has its own section.

-- ---------- rooms: time zone changes and room names ----------

-- Changing a room's time zone:
--   * shifts that have started stay as they are;
--   * every upcoming shift keeps its day and its 08:00 start and end in the new zone;
--   * the first upcoming one can't start in the past or before the running shift ends: it then starts when it was
--     due to, or when that shift ends, and still ends at 08:00. A shift shortened like that gets its whole day back
--     on a later change (its start is taken as 08:00 the day before its end), so a round trip restores the schedule;
--   * if a shift would be left with no time at all, nothing changes and the admin is told to try later.
-- The shifts move in two passes (first far into the future, then to their new times), because unique
-- (room_id, starts_at) is checked row by row: between zones exactly 24 hours apart each shift used to land on the
-- next day's shift before that one had moved.

-- the new start and end of every upcoming shift of a room (used by set_room_tz)
create or replace function private.room_tz_plan(p_room uuid, p_old text, p_new text)
returns table (id uuid, ns timestamptz, ne timestamptz)
language sql stable set search_path = '' as $$
  with e as (select max(ends_at) e from public.shifts where room_id = p_room and starts_at <= now()),
  w as (select s.id, s.starts_at os,
               least(s.starts_at at time zone p_old, (s.ends_at at time zone p_old) - interval '1 day') at time zone p_new ns,
               (s.ends_at at time zone p_old) at time zone p_new ne
        from public.shifts s where s.room_id = p_room and s.starts_at > now())
  select w.id,
         case when w.ns <= now() or w.ns < coalesce(e.e, '-infinity') then greatest(w.os, coalesce(e.e, w.os)) else w.ns end,
         w.ne
  from w cross join e
$$;
revoke all on function private.room_tz_plan(uuid, text, text) from public, anon, authenticated;

create or replace function public.set_room_tz(p_room uuid, p_tz text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_old text;
begin
  if not private.is_admin(p_room) then raise exception 'Not allowed'; end if;
  if not private.valid_tz(p_tz) then raise exception 'Unknown time zone.'; end if;
  select tz into v_old from public.rooms where id = p_room for update;
  if v_old = p_tz then return; end if;
  if exists (select 1 from private.room_tz_plan(p_room, v_old, p_tz) p where p.ns >= p.ne) then
    raise exception 'This time zone can''t be set now: a shift would have no time left. Try again after it starts.';
  end if;
  with p as (select * from private.room_tz_plan(p_room, v_old, p_tz))
  update public.shifts s set starts_at = p.ns + interval '100000 years', ends_at = p.ne + interval '100000 years'
    from p where s.id = p.id and (s.starts_at <> p.ns or s.ends_at <> p.ne);
  update public.shifts s set starts_at = s.starts_at - interval '100000 years', ends_at = s.ends_at - interval '100000 years'
    where s.room_id = p_room and s.starts_at > now() + interval '50000 years';
  update public.rooms set tz = p_tz where id = p_room;
end $$;
revoke all on function public.set_room_tz(uuid, text) from public, anon;
grant execute on function public.set_room_tz(uuid, text) to authenticated;

-- A new room's name gets a clear message instead of the raw check-constraint error (same test as rooms.name).
create or replace function public.create_room(p_id uuid, p_name text, p_icon text, p_bg text, p_type text, p_tz text)
returns uuid language plpgsql security definer set search_path = '' as $$
begin
  if coalesce(p_name, '') !~ '^[^<>"&]{1,80}$' then
    raise exception 'Room names can have up to 80 characters, without angle brackets, quotes or ampersands.';
  end if;
  perform public.create_room(p_id, p_name, p_icon, p_bg, p_type);
  update public.rooms set tz = case when private.valid_tz(p_tz) then p_tz else 'UTC' end where id = p_id;
  return p_id;
end $$;
revoke all on function public.create_room(uuid, text, text, text, text, text) from public, anon;
grant execute on function public.create_room(uuid, text, text, text, text, text) to authenticated;

-- ---------- CSV import and rules ----------

-- add_shifts creates shifts and their people in one transaction, so a refused person can't leave an empty shift
-- behind (the app used to insert the shift, then its people, as two requests). p_shifts:
-- [{id, starts_at, ends_at, shift_type, m: [user ids in order]}]. Same checks as the table policies (members add
-- shifts that haven't started; a member adds only themselves, admins anyone in the room), plus: no shift may overlap
-- one already in the room. The people go through the shift_members_follow_rules trigger as usual, so a member's
-- shifts can't break their rest, maximum or overlap rules; if any shift is refused, nothing is added.
-- The direct inserts the previous app version makes stay allowed.
create or replace function public.add_shifts(p_room uuid, p_shifts jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); adm boolean := private.is_admin(p_room); v_tz text; v_type text;
        x jsonb; v_id uuid; v_st timestamptz; v_en timestamptz; v_u uuid; i int;
begin
  if not private.is_member(p_room) then raise exception 'Not allowed'; end if;
  if jsonb_typeof(p_shifts) is distinct from 'array' or jsonb_array_length(p_shifts) not between 1 and 1000 then
    raise exception 'Nothing to import.';
  end if;
  select tz, shift_type into v_tz, v_type from public.rooms where id = p_room;
  for x in select e from jsonb_array_elements(p_shifts) e order by (e ->> 'starts_at')::timestamptz loop
    v_id := coalesce((x ->> 'id')::uuid, gen_random_uuid());
    v_st := (x ->> 'starts_at')::timestamptz;
    v_en := (x ->> 'ends_at')::timestamptz;
    if v_st <= now() then raise exception 'This shift already started.'; end if;
    if exists (select 1 from public.shifts s where s.room_id = p_room and s.starts_at < v_en and s.ends_at > v_st) then
      raise exception '%: a shift already exists', to_char(v_st at time zone v_tz, 'YYYY-MM-DD');
    end if;
    if jsonb_typeof(x -> 'm') is distinct from 'array' or jsonb_array_length(x -> 'm') = 0 then
      raise exception 'Choose at least one person.';
    end if;
    insert into public.shifts (id, room_id, starts_at, ends_at, shift_type)
      values (v_id, p_room, v_st, v_en, coalesce(x ->> 'shift_type', v_type));
    i := 0;
    for v_u in select (m.v #>> '{}')::uuid from jsonb_array_elements(x -> 'm') with ordinality m(v, o) order by m.o loop
      if not private.is_user_member(p_room, v_u) or (not adm and v_u is distinct from uid) then
        raise exception 'Not allowed';
      end if;
      insert into public.shift_members (shift_id, room_id, user_id, pos) values (v_id, p_room, v_u, i);
      i := i + 1;
    end loop;
  end loop;
end $$;
revoke all on function public.add_shifts(uuid, jsonb) from public, anon;
grant execute on function public.add_shifts(uuid, jsonb) to authenticated;

-- A tag can't be deleted while a rule uses it (the app checked this, the database didn't: a second admin's stale tab
-- or a direct call could leave a rule pointing at a missing tag). Deleting the whole room still takes its tags along.
create or replace function private.tag_unused() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_rule text;
begin
  if not exists (select 1 from public.rooms where id = old.room_id) then return old; end if;
  select r.name into v_rule from public.room_rules r
  where r.room_id = old.room_id
    and (old.id = any(r.tags)
         or exists (select 1 from jsonb_array_elements(case when jsonb_typeof(r.conds) = 'array' then r.conds else '[]' end) c
                    where jsonb_typeof(c -> 'tags') = 'array' and c -> 'tags' ? old.id::text))
  order by r.created_at limit 1;
  if v_rule is not null then raise exception '"%" uses this tag. Change or delete that rule first.', v_rule; end if;
  return old;
end $$;
revoke all on function private.tag_unused() from public, anon, authenticated;
create or replace trigger room_tags_unused_before_delete before delete on public.room_tags
  for each row execute function private.tag_unused();

-- ...and a rule can only use tags that exist in its room. The tags are locked while the rule is saved, so a tag
-- deleted at the same moment either waits for the rule (and is then refused) or is gone first (and the rule is refused).
create or replace function private.rule_tags_exist() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_ids text[];
begin
  select coalesce(array_agg(distinct t), '{}') into v_ids from (
    select unnest(coalesce(new.tags, '{}'))::text t
    union all
    select jsonb_array_elements_text(c -> 'tags')
    from jsonb_array_elements(case when jsonb_typeof(new.conds) = 'array' then new.conds else '[]' end) c
    where jsonb_typeof(c -> 'tags') = 'array') u;
  perform 1 from public.room_tags rt where rt.room_id = new.room_id and rt.id::text = any(v_ids) for share;
  if (select count(*) from public.room_tags rt where rt.room_id = new.room_id and rt.id::text = any(v_ids)) < cardinality(v_ids) then
    raise exception 'A tag in this rule was deleted. Choose the tags again.';
  end if;
  return new;
end $$;
revoke all on function private.rule_tags_exist() from public, anon, authenticated;
create or replace trigger room_rules_tags_exist before insert or update of tags, conds on public.room_rules
  for each row execute function private.rule_tags_exist();

-- A rule left pointing at a tag that no longer exists (from before the checks above) says "(deleted tag)" in its
-- messages instead of "people", which read as if it applied to anyone. Otherwise the same as in 20261011000000.
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
                     where rt.room_id = p_room and rt.id::text in (select jsonb_array_elements_text(c.v -> 'tags'))),
                    case when jsonb_array_length(coalesce(c.v -> 'tags', '[]')) > 0 then '(deleted tag)' else 'people' end) who
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

-- ---------- swaps and approvals ----------

-- Sale prices are whole euros from 1 to 100000 (the column stays an int from 0 to 100000; 0 is for requests that
-- aren't sales). The app used to round 0.4 to a €0 sale. A trigger rather than a check constraint, so requests
-- already stored as a €0 sale can still be cancelled or voided: only a new sale, or a changed price, is checked.
create or replace function private.sale_has_price() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.sell and new.price < 1
     and (tg_op = 'INSERT' or new.sell is distinct from old.sell or new.price is distinct from old.price) then
    raise exception 'Add a price to sell your shift.';
  end if;
  return new;
end $$;
revoke all on function private.sale_has_price() from public, anon, authenticated;
create or replace trigger requests_sale_has_price before insert or update of sell, price on public.requests
  for each row execute function private.sale_has_price();

-- A request that closes (cancelled by its owner, voided because its shift changed hands in another swap, or done)
-- closes its pending offers too: they used to stay "pending" on a closed request. The app tells their makers.
create or replace function private.close_request_offers() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.offers set status = 'void' where request_id = new.id and status = 'pending';
  return null;
end $$;
revoke all on function private.close_request_offers() from public, anon, authenticated;
create or replace trigger requests_close_offers after update of status on public.requests
  for each row when (old.status in ('open', 'waiting') and new.status in ('void', 'done'))
  execute function private.close_request_offers();

-- The offer a swap waits on (for an admin) is withdrawn by its maker, declined or voided: the request opens again
-- for other offers, or closes if its shift has started. So the offerer can step back while the admin hasn't decided
-- (the owner already could cancel: "owner cancels a request" covers 'waiting').
-- The server's functions lock the request before its offers (see "Lock order" below), so it is already theirs here.
-- A direct update of the previous app version locked the offer first: if someone else holds the request (an admin
-- deciding, the owner cancelling), waiting for it could deadlock, so that update is refused instead.
create or replace function private.reopen_waiting_request() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.requests where id = new.request_id and status = 'waiting' and accepted_offer = new.id) then
    return null;
  end if;
  begin
    perform 1 from public.requests where id = new.request_id for update nowait;
  exception when lock_not_available then
    raise exception 'This offer is no longer available.';
  end;
  update public.requests r
    set status = case when private.shift_open(r.shift_id) then 'open' else 'void' end, taker_id = null, accepted_offer = null
    where r.id = new.request_id and r.status = 'waiting' and r.accepted_offer = new.id;
  return null;
end $$;
revoke all on function private.reopen_waiting_request() from public, anon, authenticated;
create or replace trigger offers_reopen_request after update of status on public.offers
  for each row when (old.status = 'pending' and new.status in ('withdrawn', 'declined', 'void'))
  execute function private.reopen_waiting_request();

-- offers left pending on requests that closed before the trigger above existed: closed the same way (their requests
-- aren't waiting, so nothing reopens)
update public.offers o set status = 'void'
  where o.status = 'pending' and exists (select 1 from public.requests q where q.id = o.request_id and q.status in ('void', 'done'));

-- An admin who is part of a swap (its owner or taker) doesn't decide on it while another admin can. If every admin
-- of the room is part of it, they decide, so the swap never gets stuck.
create or replace function private.can_decide(p_room uuid, p_owner uuid, p_taker uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select private.is_admin(p_room)
    and ((auth.uid() is distinct from p_owner and auth.uid() is distinct from p_taker)
         or not exists (select 1 from public.room_members m where m.room_id = p_room and m.is_admin
                        and m.user_id is distinct from p_owner and m.user_id is distinct from p_taker))
$$;
revoke all on function private.can_decide(uuid, uuid, uuid) from public, anon, authenticated;

-- true when a swap waiting for an admin can't happen any more because one of its shifts has started
create or replace function private.waiting_started(r public.requests) returns boolean
language sql stable security definer set search_path = '' as $$
  select not private.shift_open(r.shift_id)
    or exists (select 1 from public.offers o, jsonb_array_elements(o.changes) x
               where o.id = r.accepted_offer and not private.shift_open((x ->> 'sid')::uuid))
$$;
revoke all on function private.waiting_started(public.requests) from public, anon, authenticated;

-- A swap still waiting for an admin when one of its shifts starts expires: nothing moves; the request closes if its own
-- shift started (else it opens again for other offers) and the owner and the taker are told, once.
create or replace function private.expire_waiting(r public.requests) returns void
language plpgsql security definer set search_path = '' as $$
declare v_date text;
begin
  if private.shift_open(r.shift_id) then
    update public.offers set status = 'void' where id = r.accepted_offer and status = 'pending';
    update public.requests set status = 'open', taker_id = null, accepted_offer = null where id = r.id and status = 'waiting';
  else
    update public.requests set status = 'void' where id = r.id;
  end if;
  select to_char(s.starts_at at time zone ro.tz, 'Dy FMDD Mon') into v_date
    from public.shifts s join public.rooms ro on ro.id = s.room_id where s.id = r.shift_id;
  insert into public.notifications (user_id, room_id, text, sub, dedupe)
    select u, r.room_id, format('The swap on %s expired', v_date), 'The shift started before an admin approved it.',
           'expired:' || r.id || ':' || r.accepted_offer
    from unnest(array[r.owner_id, r.taker_id]) u
    where u is not null and private.is_user_member(r.room_id, u)
  on conflict (user_id, dedupe) do nothing;
end $$;
revoke all on function private.expire_waiting(public.requests) from public, anon, authenticated;

-- Any member's app calls this when it sees such a swap (on load and as the clock moves); returns how many expired.
create or replace function public.expire_swaps(p_room uuid) returns int
language plpgsql security definer set search_path = '' as $$
declare r public.requests; n int := 0;
begin
  if auth.uid() is null or not private.is_member(p_room) then raise exception 'Not allowed'; end if;
  perform 1 from public.rooms where id = p_room for no key update;
  for r in select q.* from public.requests q where q.room_id = p_room and q.status = 'waiting' order by q.id for update loop
    if private.waiting_started(r) then perform private.expire_waiting(r); n := n + 1; end if;
  end loop;
  return n;
end $$;
revoke all on function public.expire_swaps(uuid) from public, anon;
grant execute on function public.expire_swaps(uuid) to authenticated;

-- ---------- who may write notifications, activity lines and offers ----------

-- Members used to be able to send any roommate a notification with any text, importance and dedupe key (and so
-- pass for an admin or the app, or use up the key of someone's shift reminder so it never arrived), and to write
-- any line in the room's activity log. Now:
--   * the notifications about approvals and decisions are written by the server, in request_approval, apply_swap
--     and decline_swap (as expire_swaps, join_room, leave_room and remove_member already did). The copies earlier
--     app versions still send are skipped without an error;
--   * what an app sends someone else is checked (vet_notification): kind 'req', no dedupe key, unread; important or
--     urgent only between a request's owner and a colleague it notified, at that request's importance (otherwise it
--     arrives as normal); and, from a member who isn't an admin of the room, only the texts the app sends, starting
--     with the sender's own name ("Ana S. declined your offer"). Anything else is skipped without an error, so an
--     app never stops halfway through an action;
--   * reminders (kind 'rem') and dedupe keys only for yourself, the keys starting with your own user id;
--   * activity lines from a member who isn't an admin: only the app's, starting with their own name; every line
--     records who wrote it (activity.user_id).
-- Still possible: admins write any text to members of their room and any activity line (their user id is
-- recorded); a member sends their own name-prefixed texts to any roommate, with any sub-line, and as many as they
-- like; mute preferences are applied by the sender's app.
-- Inserts from the database's own functions (they run as their owner, not as 'authenticated') aren't checked.

-- the rest of a text after the current user's short name ("Ana S. declined…" -> "declined…"), or null
create or replace function private.after_my_name(t text) returns text
language plpgsql stable security definer set search_path = '' as $$
declare n text; s text; p text[];
begin
  select name into n from public.profiles where id = auth.uid();
  if not found then return null; end if;
  s := private.short_name(n);
  if left(t, length(s) + 1) = s || ' ' then return substr(t, length(s) + 2); end if;
  -- the app capitalises the last-name initial itself, which for some letters differs from upper()
  p := regexp_split_to_array(trim(n), '\s+');
  if array_length(p, 1) > 1 and left(t, length(p[1]) + 1) = p[1] || ' ' and substr(t, length(p[1]) + 2) ~ '^\S\. ' then
    return substr(t, length(p[1]) + 5);
  end if;
  return null;
end $$;
revoke all on function private.after_my_name(text) from public, anon;
grant execute on function private.after_my_name(text) to authenticated;

-- runs as the caller (current_user tells an app's insert from a database function's)
create or replace function private.vet_notification() returns trigger
language plpgsql set search_path = '' as $$
declare uid uuid := auth.uid();
begin
  if current_user <> 'authenticated' then return new; end if;
  if uid is null then raise exception 'Not allowed'; end if;
  new.created_at := now();
  -- the server writes these itself (see above)
  if new.text ~ '( need your approval| accepted your offer · waiting for admin| took your shift( · €[0-9]+)?|^Your new shift is confirmed|^Another offer was accepted for .+|^Your request for .+ was closed|''s request for .+ was closed|^Admin declined the swap|^The swap on .+ (was not approved|expired)| left the room .+| removed you from .+)$' then
    return null;
  end if;
  if new.user_id = uid then
    if new.dedupe is not null and left(new.dedupe, 37) <> uid::text || '|' then raise exception 'Not allowed'; end if;
    return new;
  end if;
  if new.kind <> 'req' or new.dedupe is not null then raise exception 'Not allowed'; end if;
  new.read := false;
  if new.importance <> 'normal' and not exists (
       select 1 from public.requests q
       where q.room_id = new.room_id and q.status in ('open', 'waiting') and q.importance = new.importance
         and ((q.owner_id = uid and new.user_id = any (q.notified)) or (q.owner_id = new.user_id and uid = any (q.notified)))) then
    new.importance := 'normal';
  end if;
  if private.is_admin(new.room_id) then return new; end if;
  if coalesce(private.after_my_name(new.text) ~ ('^(joined your .+ shift|replied in .+|is selling .+|wants to change .+'
       || '|wants to buy .+|can swap with you on .+|declined your offer|cancelled the request for .+|withdrew from the swap on .+)$'), false) then
    return new;
  end if;
  return null;
end $$;
revoke all on function private.vet_notification() from public, anon, authenticated;
create or replace trigger notifications_vet before insert on public.notifications
  for each row execute function private.vet_notification();

alter table public.activity add column if not exists user_id uuid references public.profiles (id) on delete set null;

create or replace function private.vet_activity() returns trigger
language plpgsql set search_path = '' as $$
declare v_rest text;
begin
  new.user_id := auth.uid();
  if current_user <> 'authenticated' then return new; end if;
  -- leave_room and remove_member write these themselves
  if new.text ~ '^.+ (left the room|removed .+ from the room)$' then return null; end if;
  if private.is_admin(new.room_id) then return new; end if;
  if new.text like 'Auto-approved: %' then
    v_rest := private.after_my_name(substr(new.text, 16));
    if coalesce(v_rest ~ '^↔ .+ on .+\. Before and after saved\.$', false) then return new; end if;
  elsif coalesce(private.after_my_name(new.text) ~ ('^(added their shift on .+|removed their shift on .+|posted .+ \([0-9]+ notified\)'
          || '|cancelled a request|offered .+|accepted .+''s offer — waiting for admin|imported [0-9]+ shifts)$'), false) then
    return new;
  end if;
  return null;
end $$;
revoke all on function private.vet_activity() from public, anon, authenticated;
create or replace trigger activity_vet before insert on public.activity
  for each row execute function private.vet_activity();

-- An offer's owner or offerer could rewrite every column of it while declining or withdrawing it (repoint it to
-- another request or room); the owner of a request likewise while cancelling it. The app only ever changes their
-- status, so that is the only column it may update; the database's functions and triggers change the rest.
revoke update on public.offers from authenticated;
grant update (status) on public.offers to authenticated;
revoke update on public.requests from authenticated;
grant update (status) on public.requests to authenticated;

-- Lock order. Every function that changes swaps locks the room, then the request(s), then the offers, the order the
-- triggers above follow too (requests_close_offers: request, then its offers). An offer's request and changes never
-- change, so they are read before it is locked. The previous app version's direct withdraw (or decline) of the offer a
-- swap waits on locks the offer first; offers_reopen_request then refuses it rather than wait for a request someone
-- else holds.

-- swaps: as in 20261012000000, but an admin who is part of the swap can't approve it while another admin can, the
-- people concerned are told here (the app used to send these notifications itself), and the locks follow the order above
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
        and q.shift_id in (select (x ->> 'sid')::uuid from jsonb_array_elements(o.changes) x)
    union all
    select distinct f.from_id, q.room_id,
           format('%s''s request for %s was closed', private.short_name(p.name), to_char(s.starts_at at time zone ro.tz, 'Dy FMDD Mon')),
           'Your offer is closed.', 'closed:' || q.id
      from public.requests q join public.shifts s on s.id = q.shift_id join public.rooms ro on ro.id = q.room_id
        join public.profiles p on p.id = q.owner_id join public.offers f on f.request_id = q.id and f.status = 'pending'
      where q.id <> r.id and q.status in ('open', 'waiting')
        and q.shift_id in (select (x ->> 'sid')::uuid from jsonb_array_elements(o.changes) x)
  on conflict (user_id, dedupe) do nothing;

  -- (the requests_close_offers trigger voids the other offers of every request closed here)
  update public.requests set status = 'done', taker_id = o.from_id where id = r.id;
  update public.offers set status = 'accepted' where id = o.id;
  update public.offers set status = 'void' where request_id = r.id and status = 'pending';
  update public.requests set status = 'void'
    where id <> r.id and status in ('open', 'waiting')
      and shift_id in (select (x ->> 'sid')::uuid from jsonb_array_elements(o.changes) x);

  insert into public.messages (room_id, text, sys) values (r.room_id,
    format('%s''s %s shift now goes to %s%s ✓', v_owner, v_date, v_taker, case when r.sell then ' · €' || r.price else '' end), true);
end $$;


-- the owner accepts an offer in a room that needs admin approval: as in 20261012000000, and the admins who can
-- decide (see can_decide) and the offerer are told here; locks in the order above
create or replace function public.request_approval(p_offer bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare o public.offers; r public.requests; v_owner text; v_taker text;
begin
  perform 1 from public.rooms where id = (select x.room_id from public.offers x where x.id = p_offer) for no key update;
  select * into r from public.requests where id = (select x.request_id from public.offers x where x.id = p_offer) for update;
  select * into o from public.offers where id = p_offer for update;
  if not found or o.status <> 'pending' then raise exception 'This offer is no longer available.'; end if;
  if r.owner_id <> auth.uid() then raise exception 'Not allowed'; end if;
  if r.status <> 'open' then raise exception 'This request is no longer open.'; end if;
  if not (select approval_mode from public.rooms where id = r.room_id) then raise exception 'Not allowed'; end if;
  if not private.shift_open(r.shift_id) then raise exception 'This shift already started.'; end if;
  update public.requests set status = 'waiting', taker_id = o.from_id, accepted_offer = o.id where id = r.id;
  select private.short_name(name) into v_owner from public.profiles where id = r.owner_id;
  select private.short_name(name) into v_taker from public.profiles where id = o.from_id;
  insert into public.notifications (user_id, room_id, text, dedupe)
    select m.user_id, r.room_id, format('%s and %s need your approval', v_taker, v_owner), 'approve:' || o.id
      from public.room_members m
      where m.room_id = r.room_id and m.is_admin and m.user_id <> r.owner_id
        and (m.user_id <> o.from_id or not exists (select 1 from public.room_members a where a.room_id = r.room_id
                                                    and a.is_admin and a.user_id not in (r.owner_id, o.from_id)))
    union all
    select o.from_id, r.room_id, format('%s accepted your offer · waiting for admin', v_owner), 'accepted:' || o.id
  on conflict (user_id, dedupe) do nothing;
end $$;

-- an admin declines a swap waiting for approval: as in 20261012000000, but not an admin who is part of it while another
-- admin can decide (they cancel or withdraw instead), and a swap whose shift has started closes instead of reopening.
-- Its owner and taker are told here. When the swap can't happen any more (someone's shifts changed, or it would now
-- break a rule: the app declines it then), they are told why. Locks in the order above.
create or replace function public.decline_swap(p_request bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.requests; o public.offers; v_gone boolean; v_why text; v_date text;
begin
  perform 1 from public.rooms where id = (select q.room_id from public.requests q where q.id = p_request) for no key update;
  select * into r from public.requests where id = p_request for update;
  if not found or not private.is_admin(r.room_id) then raise exception 'Not allowed'; end if;
  if r.status <> 'waiting' then raise exception 'This request is no longer open.'; end if;
  if not private.can_decide(r.room_id, r.owner_id, r.taker_id) then
    raise exception 'Another admin has to approve a swap you are part of.';
  end if;
  v_gone := not private.shift_open(r.shift_id);
  select * into o from public.offers where id = r.accepted_offer for update;
  if exists (select 1 from jsonb_array_elements(o.changes) c
             where not exists (select 1 from public.shift_members m where m.shift_id = (c ->> 'sid')::uuid and m.user_id = (c ->> 'out')::uuid)
                or exists (select 1 from public.shift_members m where m.shift_id = (c ->> 'sid')::uuid and m.user_id = (c ->> 'in')::uuid)) then
    v_why := 'That offer is no longer possible.';
  elsif not v_gone then
    select 'That swap breaks a rule. ' || x.msg into v_why from private.new_violations(r.room_id, o.changes) x limit 1;
  end if;
  update public.offers set status = 'declined' where id = r.accepted_offer and status = 'pending';
  update public.requests set status = case when v_gone then 'void' else 'open' end, taker_id = null, accepted_offer = null
    where id = r.id;
  select to_char(s.starts_at at time zone ro.tz, 'Dy FMDD Mon') into v_date
    from public.shifts s join public.rooms ro on ro.id = s.room_id where s.id = r.shift_id;
  insert into public.notifications (user_id, room_id, text, sub, dedupe)
    select u, r.room_id, case when v_why is null then 'Admin declined the swap' else format('The swap on %s was not approved', v_date) end,
           left(regexp_replace(v_why, '[<>]', '', 'g'), 300), 'declined:' || r.accepted_offer
      from unnest(array[r.taker_id, r.owner_id]) u
      where u is not null and private.is_user_member(r.room_id, u)
  on conflict (user_id, dedupe) do nothing;
end $$;

-- ---------- reports and the developer dashboard ----------

-- Why a request closed without a swap: 'cancelled' when its owner closed it from the app (cancelled it, or removed
-- themselves from its shift), 'system' when the server closed it (its shift changed hands in another swap, a waiting
-- swap expired or was declined after the shift started, its owner left or was removed from the room). Reports used to
-- count every one of these as "Cancelled". Set by a trigger, so the app (old or new) can't choose it: the only direct
-- update of a request's status is the owner's own (policy "owner cancels a request"); everything else goes through
-- SECURITY DEFINER functions, which run as their owner (cancel_request, below, is the one that says 'cancelled').
alter table public.requests add column if not exists close_reason text check (close_reason in ('cancelled', 'system'));

-- requests closed before this column existed: best guess. The owner still on the shift and no swap that was waiting
-- for an admin (an expired one keeps its taker) means they cancelled it; otherwise the system closed it.
update public.requests r set close_reason = case
    when r.taker_id is null and exists (select 1 from public.shift_members m where m.shift_id = r.shift_id and m.user_id = r.owner_id)
    then 'cancelled' else 'system' end
  where r.status = 'void' and r.close_reason is null;

create or replace function private.request_close_reason() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.status <> 'void' then
    new.close_reason := null;
  elsif tg_op = 'UPDATE' and old.status = 'void' then
    new.close_reason := old.close_reason;
  elsif current_user = 'authenticated' then
    new.close_reason := case when new.owner_id = auth.uid() then 'cancelled' else 'system' end;
  else
    -- the server's functions: 'cancelled' when they say so (cancel_request), else 'system'
    new.close_reason := coalesce(new.close_reason, 'system');
  end if;
  return new;
end $$;
revoke all on function private.request_close_reason() from public, anon, authenticated;
create or replace trigger requests_close_reason before insert or update on public.requests
  for each row execute function private.request_close_reason();

-- Reports: 'cancelled' counts only the requests their owner cancelled; 'closed' (new) the ones the system closed and
-- the ones still open whose shift has started (nobody can take them any more); 'open' only the ones that can still be
-- filled. Otherwise as in 20261010000000. The previous app shows 'open' and 'cancelled' and ignores 'closed'.
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
    select id, starts_at, extract(epoch from ends_at - starts_at) / 3600.0 as hrs
    from public.shifts where room_id = p_room and starts_at >= m0 and starts_at < m1),
  seats as (
    select m.user_id, s.hrs from sh s join public.shift_members m on m.shift_id = s.id),
  rq as (
    select r.owner_id, r.taker_id, r.status, r.sell, r.price, r.close_reason, sh.starts_at <= now() as started,
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
    'open', (select count(*) from rq where status in ('open', 'waiting') and not started),
    'cancelled', (select count(*) from rq where status = 'void' and close_reason = 'cancelled'),
    'closed', (select count(*) from rq where (status = 'void' and close_reason is distinct from 'cancelled')
                                          or (status in ('open', 'waiting') and started)),
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
revoke all on function public.room_report(uuid, date) from public, anon;
grant execute on function public.room_report(uuid, date) to authenticated;

-- ---------- cancelling, withdrawing and leaving in the lock order (room, request, offers) ----------

-- The owner cancels their request (open, or waiting for an admin): what the policy "owner cancels a request" allows,
-- with the room and the request locked first, like apply_swap and decline_swap, so an admin deciding at the same
-- moment waits instead of deadlocking. Its pending offers close (requests_close_offers). The app uses this live.
create or replace function public.cancel_request(p_request bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.requests;
begin
  if auth.uid() is null then raise exception 'Not allowed'; end if;
  perform 1 from public.rooms where id = (select q.room_id from public.requests q where q.id = p_request) for no key update;
  select * into r from public.requests where id = p_request for update;
  if not found or r.owner_id <> auth.uid() then raise exception 'Not allowed'; end if;
  if r.status not in ('open', 'waiting') then raise exception 'This request is no longer open.'; end if;
  perform 1 from public.offers where request_id = r.id and status = 'pending' order by id for update;
  update public.requests set status = 'void', close_reason = 'cancelled' where id = r.id;
end $$;
revoke all on function public.cancel_request(bigint) from public, anon;
grant execute on function public.cancel_request(bigint) to authenticated;

-- The offerer withdraws their pending offer: what the policy "offerer withdraws" allows, in the same lock order. If a
-- swap was waiting on it, the request opens again (offers_reopen_request). The app uses this live.
create or replace function public.withdraw_offer(p_offer bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare o public.offers;
begin
  if auth.uid() is null then raise exception 'Not allowed'; end if;
  perform 1 from public.rooms where id = (select x.room_id from public.offers x where x.id = p_offer) for no key update;
  perform 1 from public.requests where id = (select x.request_id from public.offers x where x.id = p_offer) for update;
  select * into o from public.offers where id = p_offer for update;
  if not found or o.from_id <> auth.uid() then raise exception 'Not allowed'; end if;
  if o.status <> 'pending' then raise exception 'This offer is no longer available.'; end if;
  update public.offers set status = 'withdrawn' where id = o.id;
end $$;
revoke all on function public.withdraw_offer(bigint) from public, anon;
grant execute on function public.withdraw_offer(bigint) to authenticated;

-- leave_room and remove_member: as in 20261012000000, but the requests drop_member changes (theirs, the ones waiting
-- on them, the ones they made offers on) are locked before it closes their offers
create or replace function private.lock_member_requests(p_room uuid, p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform 1 from public.requests q
  where q.room_id = p_room and q.status in ('open', 'waiting')
    and (q.owner_id = p_user or q.taker_id = p_user
         or exists (select 1 from public.offers f where f.request_id = q.id and f.from_id = p_user and f.status = 'pending'))
  order by q.id for update;
end $$;
revoke all on function private.lock_member_requests(uuid, uuid) from public, anon, authenticated;

create or replace function public.leave_room(p_room uuid) returns void
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
  perform private.lock_member_requests(p_room, uid);
  perform private.drop_member(p_room, uid);
  select private.short_name(name) into v_name from public.profiles where id = uid;
  insert into public.activity (room_id, text) values (p_room, v_name || ' left the room');
  insert into public.notifications (user_id, room_id, text)
    select m.user_id, p_room, v_name || ' left the room ' || v_room from public.room_members m where m.room_id = p_room and m.is_admin;
end $$;

create or replace function public.remove_member(p_room uuid, p_user uuid) returns int
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); v_room text; v_who text; v_name text; n int;
begin
  select name into v_room from public.rooms where id = p_room and deleted_at is null for no key update;
  if not found or not private.is_admin(p_room) then raise exception 'Not allowed'; end if;
  if p_user = uid or not private.is_user_member(p_room, p_user) then raise exception 'Not allowed'; end if;
  perform private.lock_member_requests(p_room, p_user);
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

-- Dashboard owners: only owners who can open the dashboard (a confirmed account, not revoked) count toward "at least
-- one owner". An address with no confirmed account used to count, so the last real owner could remove themselves and
-- nobody could open the dashboard. The list is locked first, so two owners removing each other at the same moment
-- can't both pass the check.
create or replace function public.remove_app_admin(p_email text) returns void
language plpgsql security definer set search_path = '' as $$
declare v text := lower(trim(p_email));
begin
  if not private.is_app_admin() then raise exception 'Not allowed'; end if;
  lock table public.app_admins in share row exclusive mode;
  if not exists (select 1 from public.app_admins a
                 where a.revoked_at is null and a.email <> v
                   and exists (select 1 from auth.users u where lower(u.email) = a.email and u.email_confirmed_at is not null)) then
    raise exception 'The dashboard needs at least one owner.';
  end if;
  update public.app_admins set revoked_at = now() where email = v and revoked_at is null;
end $$;
revoke all on function public.remove_app_admin(text) from public, anon;
grant execute on function public.remove_app_admin(text) to authenticated;
