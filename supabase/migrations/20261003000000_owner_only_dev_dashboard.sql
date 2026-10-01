-- The developer dashboard is for the app owner only.
-- app_admins holds the owner emails. It's filled per project with SQL (see README), never from this repo, which is public.
-- An account counts as owner only if its email is on the list AND confirmed, so nobody can claim it by signing up with that address.

create table public.app_admins (
  email text primary key check (email = lower(email)),
  added_at timestamptz not null default now()
);
alter table public.app_admins enable row level security;  -- no policies: nobody reads or writes it through the API
revoke all on public.app_admins from anon, authenticated;

create function private.is_app_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.app_admins a join auth.users u on lower(u.email) = a.email
    where u.id = (select auth.uid()) and u.email_confirmed_at is not null)
$$;
revoke all on function private.is_app_admin() from public, anon;
grant execute on function private.is_app_admin() to authenticated;

-- lets the app decide whether to show the dashboard button
create function public.am_app_admin() returns boolean
language sql stable security definer set search_path = '' as $$ select private.is_app_admin() $$;
revoke all on function public.am_app_admin() from public, anon;
grant execute on function public.am_app_admin() to authenticated;

-- ---------- usage events: counts only, never message text ----------

create table public.app_events (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  room_id uuid references public.rooms (id) on delete set null,
  name text not null check (name ~ '^[a-z_]{1,40}$'),
  props jsonb not null default '{}' check (jsonb_typeof(props) = 'object' and pg_column_size(props) < 2000),
  created_at timestamptz not null default now()
);
create index app_events_created_idx on public.app_events (created_at);

alter table public.app_events enable row level security;
create policy "people record their own usage" on public.app_events for insert to authenticated
  with check (user_id = (select auth.uid()) and (room_id is null or private.is_member(room_id)));
create policy "only the owner reads usage" on public.app_events for select to authenticated
  using (private.is_app_admin());
revoke all on public.app_events from anon;

-- rooms overview for the dashboard: every room, not just the owner's own
create function public.dev_rooms() returns table (id uuid, name text, icon text, members int)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_app_admin() then raise exception 'Not allowed'; end if;
  return query select r.id, r.name, r.icon, (select count(*)::int from public.room_members m where m.room_id = r.id)
    from public.rooms r order by r.created_at;
end $$;
revoke all on function public.dev_rooms() from public, anon;
grant execute on function public.dev_rooms() to authenticated;

-- sign-ups are recorded by the database, since the account doesn't exist yet when the app could log it
create or replace function private.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_name text := left(regexp_replace(coalesce(nullif(trim(new.raw_user_meta_data ->> 'name'), ''),
                                              nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''),
                                              split_part(new.email, '@', 1), 'New user'), '[<>"&]', '', 'g'), 60);
begin
  if v_name = '' then v_name := 'New user'; end if;
  insert into public.profiles (id, name, avatar) values (new.id, v_name, 10 + floor(random() * 5)::int);
  insert into public.profile_private (id, email) values (new.id, new.email);
  insert into public.app_events (user_id, name, props)
    values (new.id, 'signup', jsonb_build_object('method', coalesce(new.raw_app_meta_data ->> 'provider', 'email')));
  return new;
end $$;
