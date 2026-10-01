-- New rooms start without rules: each team's admins add the ones that fit them.
-- (Renaming a room and changing its icon needs nothing new: the "admins edit room" policy already allows it.)

create or replace function public.create_room(p_id uuid, p_name text, p_icon text, p_bg text, p_type text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Not signed in'; end if;
  insert into public.rooms (id, name, icon, bg, shift_type, created_by) values (p_id, trim(p_name), p_icon, p_bg, p_type, uid);
  insert into public.room_members (room_id, user_id, is_admin) values (p_id, uid, true);
  insert into public.messages (room_id, user_id, text, tr) values (p_id, uid, 'Room created ✨', true);
  return p_id;
end $$;
