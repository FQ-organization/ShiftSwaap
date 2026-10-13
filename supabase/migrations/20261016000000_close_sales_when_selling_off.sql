-- Turning selling off in a room closes the room's open sales (open, or waiting for an admin): each request closes
-- ('system', so reports don't count it as cancelled by its owner), its pending offers close with it
-- (requests_close_offers), and its owner and the people who offered to buy are told. Before, the sales stayed live in
-- the app and apply_swap only refused them at the last step.

create or replace function private.close_sales() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.allow_sell or not old.allow_sell then return null; end if;
  insert into public.notifications (user_id, room_id, text, sub, dedupe)
    select q.owner_id, q.room_id,
           format('Your sale of %s was closed', to_char(s.starts_at at time zone ro.tz, 'Dy FMDD Mon')),
           'Selling shifts was turned off in this room.', 'nosale:' || q.id
      from public.requests q join public.shifts s on s.id = q.shift_id join public.rooms ro on ro.id = q.room_id
      where q.room_id = new.id and q.sell and q.status in ('open', 'waiting')
    union all
    select distinct f.from_id, q.room_id,
           format('%s''s sale of %s was closed', private.short_name(p.name), to_char(s.starts_at at time zone ro.tz, 'Dy FMDD Mon')),
           'Selling shifts was turned off in this room.', 'nosale:' || q.id
      from public.requests q join public.shifts s on s.id = q.shift_id join public.rooms ro on ro.id = q.room_id
        join public.profiles p on p.id = q.owner_id join public.offers f on f.request_id = q.id and f.status = 'pending'
      where q.room_id = new.id and q.sell and q.status in ('open', 'waiting')
  on conflict (user_id, dedupe) do nothing;
  update public.requests set status = 'void' where room_id = new.id and sell and status in ('open', 'waiting');
  return null;
end $$;
revoke all on function private.close_sales() from public, anon, authenticated;

create trigger rooms_close_sales after update of allow_sell on public.rooms
  for each row execute function private.close_sales();
