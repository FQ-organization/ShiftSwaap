-- Shifts that have started are history: nobody can move people on or off them, add them, delete them, or ask to swap them.
-- Restrictive policies are combined (AND) with the existing ones, so this only adds a condition.

create function private.shift_open(s uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.shifts where id = s and starts_at > now())
$$;
revoke all on function private.shift_open(uuid) from public, anon;
grant execute on function private.shift_open(uuid) to authenticated;

create policy "only future shifts are added" on public.shifts as restrictive for insert to authenticated
  with check (starts_at > now());
create policy "only future shifts are edited" on public.shifts as restrictive for update to authenticated
  using (starts_at > now()) with check (starts_at > now());
create policy "only future shifts are removed" on public.shifts as restrictive for delete to authenticated
  using (starts_at > now());

create policy "only join future shifts" on public.shift_members as restrictive for insert to authenticated
  with check (private.shift_open(shift_id));
create policy "only leave future shifts" on public.shift_members as restrictive for delete to authenticated
  using (private.shift_open(shift_id));

create policy "only request future shifts" on public.requests as restrictive for insert to authenticated
  with check (private.shift_open(shift_id));

-- an offer can only involve shifts that haven't started (the requested one and, for a swap, the offerer's)
create policy "only offer on future shifts" on public.offers as restrictive for insert to authenticated
  with check (
    exists (select 1 from public.requests r where r.id = offers.request_id and private.shift_open(r.shift_id))
    and not exists (select 1 from jsonb_array_elements(offers.changes) x
                    where not private.shift_open((x ->> 'sid')::uuid)));

create or replace function public.request_approval(p_offer bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare o public.offers; r public.requests;
begin
  select * into o from public.offers where id = p_offer for update;
  if not found or o.status <> 'pending' then raise exception 'This offer is no longer available.'; end if;
  select * into r from public.requests where id = o.request_id for update;
  if r.owner_id <> auth.uid() then raise exception 'Not allowed'; end if;
  if r.status <> 'open' then raise exception 'This request is no longer open.'; end if;
  if not (select approval_mode from public.rooms where id = r.room_id) then raise exception 'Not allowed'; end if;
  if not private.shift_open(r.shift_id) then raise exception 'This shift already started.'; end if;
  update public.requests set status = 'waiting', taker_id = o.from_id, accepted_offer = o.id where id = r.id;
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
