-- Rooms describe their people with admin-defined tags (role, level, skill...) instead of a
-- hospital-only residency year on the account. Rules are built from conditions on those tags.
-- This migration only adds things: the old rules table and profiles.year stay in place, unused.

-- ---------- tags ----------

create table public.room_tags (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms (id) on delete cascade,
  name text not null check (name ~ '^[^<>"&]{1,24}$'),
  color text not null default '#e2f2f5' check (color ~ '^#[0-9a-fA-F]{6}$'),
  created_at timestamptz not null default now(),
  unique (room_id, name),
  unique (id, room_id)
);

create table public.member_tags (
  room_id uuid not null,
  user_id uuid not null,
  tag_id uuid not null,
  primary key (tag_id, user_id),
  foreign key (tag_id, room_id) references public.room_tags (id, room_id) on delete cascade,
  foreign key (room_id, user_id) references public.room_members (room_id, user_id) on delete cascade
);
create index member_tags_room_idx on public.member_tags (room_id);
create index member_tags_user_idx on public.member_tags (user_id);

alter table public.room_tags enable row level security;
alter table public.member_tags enable row level security;

create policy "members see tags" on public.room_tags for select to authenticated
  using (private.is_member(room_id));
create policy "admins add tags" on public.room_tags for insert to authenticated
  with check (private.is_admin(room_id));
create policy "admins edit tags" on public.room_tags for update to authenticated
  using (private.is_admin(room_id)) with check (private.is_admin(room_id));
create policy "admins delete tags" on public.room_tags for delete to authenticated
  using (private.is_admin(room_id));

create policy "members see member tags" on public.member_tags for select to authenticated
  using (private.is_member(room_id));
create policy "admins tag people" on public.member_tags for insert to authenticated
  with check (private.is_admin(room_id));
create policy "admins untag people" on public.member_tags for delete to authenticated
  using (private.is_admin(room_id));

revoke all on public.room_tags, public.member_tags from anon;

-- ---------- carry existing residency years over as room tags ----------

insert into public.room_tags (room_id, name, color)
select distinct m.room_id, p.year, case when p.year in ('R1', 'R2') then '#fff0e1' else '#e8edff' end
from public.room_members m join public.profiles p on p.id = m.user_id
where p.year is not null;

insert into public.member_tags (room_id, user_id, tag_id)
select m.room_id, m.user_id, t.id
from public.room_members m
join public.profiles p on p.id = m.user_id
join public.room_tags t on t.room_id = m.room_id and t.name = p.year;

-- ---------- generic rules ----------
-- room_rules replaces rules (left in place unused, so this migration only adds things).
-- shift: conds = [{op: min|max|eq, n, tags: [tag ids]}]; every condition must hold on every shift (no tags = anyone)
-- rest:  h hours between a person's shifts, for people with any of `tags` (none = everyone)
-- max:   at most n shifts per `per` (week|month), for people with any of `tags` (none = everyone)

create table public.room_rules (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms (id) on delete cascade,
  name text not null check (name ~ '^[^<>"&]{1,80}$'),
  enabled boolean not null default true,
  type text not null check (type in ('shift', 'rest', 'max')),
  conds jsonb,
  h int check (h between 0 and 168),
  n int check (n between 0 and 366),
  per text check (per in ('week', 'month')),
  tags uuid[] not null default '{}',
  created_at timestamptz not null default now(),
  check ((type = 'shift' and jsonb_typeof(conds) = 'array')
      or (type = 'rest' and h is not null)
      or (type = 'max' and n is not null and per is not null))
);
create index room_rules_room_idx on public.room_rules (room_id);

alter table public.room_rules enable row level security;
create policy "members see room rules" on public.room_rules for select to authenticated
  using (private.is_member(room_id));
create policy "admins add room rules" on public.room_rules for insert to authenticated
  with check (private.is_admin(room_id));
create policy "admins edit room rules" on public.room_rules for update to authenticated
  using (private.is_admin(room_id)) with check (private.is_admin(room_id));
create policy "admins delete room rules" on public.room_rules for delete to authenticated
  using (private.is_admin(room_id));
revoke all on public.room_rules from anon;

insert into public.room_rules (id, room_id, name, enabled, type, conds, h, n, per, created_at)
select r.id, r.room_id, r.name, r.enabled,
  case r.type when 'rest' then 'rest' when 'max' then 'max' else 'shift' end,
  case r.type
    when 'staff' then jsonb_build_array(jsonb_build_object('op', 'min', 'n', r.n, 'tags', '[]'::jsonb))
    when 'require' then (select jsonb_agg(jsonb_build_object('op', 'min', 'n', (q ->> 'min')::int, 'tags',
        coalesce((select jsonb_agg(t.id) from public.room_tags t
                  where t.room_id = r.room_id and t.name in (select jsonb_array_elements_text(q -> 'in'))), '[]'::jsonb)))
      from jsonb_array_elements(r.req) q)
  end,
  case when r.type = 'rest' then r.h end,
  case when r.type = 'max' then r.n end,
  case when r.type = 'max' then 'month' end,
  r.created_at
from public.rules r;

-- ---------- accounts no longer carry a residency year ----------

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
  return new;
end $$;

-- profiles.year is no longer read or written; drop it from the dashboard whenever convenient

-- new rooms start with generic defaults
create or replace function public.create_room(p_id uuid, p_name text, p_icon text, p_bg text, p_type text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Not signed in'; end if;
  insert into public.rooms (id, name, icon, bg, shift_type, created_by) values (p_id, trim(p_name), p_icon, p_bg, p_type, uid);
  insert into public.room_members (room_id, user_id, is_admin) values (p_id, uid, true);
  insert into public.room_rules (room_id, name, type, conds, created_at) values
    (p_id, 'Minimum staffing', 'shift', '[{"op":"min","n":2,"tags":[]}]', now());
  insert into public.room_rules (room_id, name, type, h, created_at) values
    (p_id, 'Minimum rest', 'rest', 11, now() + interval '1 second');
  insert into public.messages (room_id, user_id, text, tr) values (p_id, uid, 'Room created ✨', true);
  return p_id;
end $$;

alter publication supabase_realtime add table public.room_tags, public.member_tags, public.room_rules;
