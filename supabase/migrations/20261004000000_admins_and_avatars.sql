-- More admins: room admins can promote other members; dashboard owners can manage the owner list from the app.
-- Avatar picker: profiles.avatar_id selects one of the app's avatar presets (profiles.avatar, 0..14, is the old default).

alter table public.profiles add column avatar_id smallint check (avatar_id between 0 and 63);

-- ---------- room admins ----------

create function public.set_room_admin(p_room uuid, p_user uuid, p_admin boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin(p_room) then raise exception 'Not allowed'; end if;
  if not private.is_user_member(p_room, p_user) then raise exception 'Not allowed'; end if;
  if not p_admin and (select count(*) from public.room_members where room_id = p_room and is_admin and user_id <> p_user) = 0 then
    raise exception 'A room needs at least one admin.';
  end if;
  update public.room_members set is_admin = p_admin where room_id = p_room and user_id = p_user;
end $$;
revoke all on function public.set_room_admin(uuid, uuid, boolean) from public, anon;
grant execute on function public.set_room_admin(uuid, uuid, boolean) to authenticated;

-- ---------- dashboard owners (app_admins), managed by owners ----------
-- Removing an owner marks the row revoked instead of deleting it, which also keeps a record of who had access.

alter table public.app_admins add column revoked_at timestamptz;

create or replace function private.is_app_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.app_admins a join auth.users u on lower(u.email) = a.email
    where a.revoked_at is null and u.id = (select auth.uid()) and u.email_confirmed_at is not null)
$$;

create function public.list_app_admins() returns table (email text, has_account boolean)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_app_admin() then raise exception 'Not allowed'; end if;
  return query select a.email, exists (select 1 from auth.users u where lower(u.email) = a.email and u.email_confirmed_at is not null)
    from public.app_admins a where a.revoked_at is null order by a.added_at;
end $$;

create function public.add_app_admin(p_email text) returns void
language plpgsql security definer set search_path = '' as $$
declare v text := lower(trim(p_email));
begin
  if not private.is_app_admin() then raise exception 'Not allowed'; end if;
  if v !~ '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$' then raise exception 'Enter a valid email.'; end if;
  insert into public.app_admins (email) values (v)
    on conflict (email) do update set revoked_at = null, added_at = now();
end $$;

create function public.remove_app_admin(p_email text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_app_admin() then raise exception 'Not allowed'; end if;
  if (select count(*) from public.app_admins where revoked_at is null and email <> lower(trim(p_email))) = 0 then
    raise exception 'The dashboard needs at least one owner.';
  end if;
  update public.app_admins set revoked_at = now() where email = lower(trim(p_email)) and revoked_at is null;
end $$;

revoke all on function public.list_app_admins() from public, anon;
revoke all on function public.add_app_admin(text) from public, anon;
revoke all on function public.remove_app_admin(text) from public, anon;
grant execute on function public.list_app_admins() to authenticated;
grant execute on function public.add_app_admin(text) to authenticated;
grant execute on function public.remove_app_admin(text) to authenticated;
