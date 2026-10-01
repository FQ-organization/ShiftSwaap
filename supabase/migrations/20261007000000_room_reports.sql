-- Monthly room report for room admins: shifts, hours, requests, swaps, sales and a per-person breakdown.
-- A month covers the shifts that start in it (UTC), and the requests made about those shifts.
--   swap:    done, not a sale, the offer traded one of the taker's shifts back (2 changes)
--   given:   done, not a sale, taken as is (1 change)
--   sale:    done and sold; sales_total sums the prices

create function public.room_report(p_room uuid, p_month date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  m0 timestamptz := date_trunc('month', p_month)::timestamp at time zone 'UTC';
  m1 timestamptz := (date_trunc('month', p_month) + interval '1 month')::timestamp at time zone 'UTC';
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
    'month', to_char(m0 at time zone 'UTC', 'YYYY-MM'),
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

revoke all on function public.room_report(uuid, date) from public, anon;
grant execute on function public.room_report(uuid, date) to authenticated;
