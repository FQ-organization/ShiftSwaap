-- Room admins can delete a room. Deleting marks it (deleted_at) instead of removing rows: every access check
-- below treats a deleted room as gone for everyone, and the data stays recoverable by the project owner.

alter table public.rooms
  add column deleted_at timestamptz,
  add column deleted_by uuid references public.profiles (id) on delete set null;

create or replace function private.is_member(r uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.room_members m join public.rooms ro on ro.id = m.room_id
                 where m.room_id = r and m.user_id = (select auth.uid()) and ro.deleted_at is null)
$$;

create or replace function private.is_admin(r uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.room_members m join public.rooms ro on ro.id = m.room_id
                 where m.room_id = r and m.user_id = (select auth.uid()) and m.is_admin and ro.deleted_at is null)
$$;

create or replace function private.is_user_member(r uuid, u uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.room_members m join public.rooms ro on ro.id = m.room_id
                 where m.room_id = r and m.user_id = u and ro.deleted_at is null)
$$;

create or replace function private.shares_room(u uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.room_members a
    join public.room_members b on a.room_id = b.room_id
    join public.rooms ro on ro.id = a.room_id
    where a.user_id = (select auth.uid()) and b.user_id = u and ro.deleted_at is null)
$$;

create function public.delete_room(p_room uuid, p_name text) returns void
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); v_room text; v_who text;
begin
  if not private.is_admin(p_room) then raise exception 'Not allowed'; end if;
  select name into v_room from public.rooms where id = p_room;
  if trim(coalesce(p_name, '')) <> v_room then raise exception 'Type the room name exactly to confirm.'; end if;
  select private.short_name(name) into v_who from public.profiles where id = uid;
  -- tell the other members before the room disappears for them
  insert into public.notifications (user_id, room_id, text)
    select m.user_id, null, v_who || ' deleted the room ' || v_room
    from public.room_members m where m.room_id = p_room and m.user_id <> uid;
  update public.invites set revoked = true where room_id = p_room and not revoked;
  update public.rooms set deleted_at = now(), deleted_by = uid where id = p_room;
end $$;
revoke all on function public.delete_room(uuid, text) from public, anon;
grant execute on function public.delete_room(uuid, text) to authenticated;

-- the owner's dashboard lists only rooms that still exist
create or replace function public.dev_rooms() returns table (id uuid, name text, icon text, members int)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_app_admin() then raise exception 'Not allowed'; end if;
  return query select r.id, r.name, r.icon, (select count(*)::int from public.room_members m where m.room_id = r.id)
    from public.rooms r where r.deleted_at is null order by r.created_at;
end $$;
