-- Urban3DQuest - secure baseline with RLS + Supabase Auth admin role
-- Apply first in staging, then production.

begin;

-- 0) Admin role source of truth (Auth users mapped to admin privileges)
create table if not exists admin_users (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table admin_users enable row level security;

drop policy if exists admin_users_self_read on admin_users;
create policy admin_users_self_read on admin_users
for select to authenticated
using (auth.uid() = user_id);

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.admin_users a
    where a.user_id = auth.uid()
  );
$$;

grant execute on function public.is_admin() to anon, authenticated;

-- 1) Enable RLS on game tables
alter table if exists treasures enable row level security;
alter table if exists players   enable row level security;
alter table if exists events    enable row level security;
alter table if exists config    enable row level security;

-- 2) Drop old policies (idempotent)
drop policy if exists treasures_read_all on treasures;
drop policy if exists treasures_update_found on treasures;
drop policy if exists treasures_admin_all on treasures;

drop policy if exists players_read_all on players;
drop policy if exists players_insert_self on players;
drop policy if exists players_update_self on players;
drop policy if exists players_admin_all on players;

drop policy if exists events_read_all on events;
drop policy if exists events_insert_all on events;
drop policy if exists events_admin_all on events;

drop policy if exists config_read_all on config;
drop policy if exists config_admin_all on config;

-- 3) Public read access needed by the player app
create policy treasures_read_all on treasures
for select to anon, authenticated
using (true);

create policy players_read_all on players
for select to anon, authenticated
using (true);

create policy events_read_all on events
for select to anon, authenticated
using (true);

create policy config_read_all on config
for select to anon, authenticated
using (true);

-- 4) Player gameplay writes (limited)
create policy players_insert_self on players
for insert to anon, authenticated
with check (
  pseudo is not null
  and length(trim(pseudo)) between 2 and 24
  and pseudo ~ '^[A-Z0-9_-]+$'
);

create policy players_update_self on players
for update to anon, authenticated
using (true)
with check (
  pseudo is not null
  and length(trim(pseudo)) between 2 and 24
  and pseudo ~ '^[A-Z0-9_-]+$'
  and found_count >= 0
  and score >= 0
);

create policy events_insert_all on events
for insert to anon, authenticated
with check (
  pseudo is not null
  and length(trim(pseudo)) between 2 and 24
  and pseudo ~ '^[A-Z0-9_-]+$'
  and duration_sec is not null
  and duration_sec >= 0
);

-- Unique claim is protected in app by update ... eq('found_by','').
create policy treasures_update_found on treasures
for update to anon, authenticated
using (true)
with check (
  found_by is not null
);

-- 5) Admin writes: only authenticated users present in admin_users
create policy treasures_admin_all on treasures
for all to authenticated
using (public.is_admin())
with check (public.is_admin());

create policy players_admin_all on players
for all to authenticated
using (public.is_admin())
with check (public.is_admin());

create policy events_admin_all on events
for all to authenticated
using (public.is_admin())
with check (public.is_admin());

create policy config_admin_all on config
for all to authenticated
using (public.is_admin())
with check (public.is_admin());

-- 6) Minimal anti-tampering safeguards for gameplay data
create unique index if not exists events_unique_pseudo_treasure
on events (pseudo, treasure_id);

create or replace function public.validate_event_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_treasure_type text;
begin
  if new.pseudo is null or length(trim(new.pseudo)) < 2 then
    raise exception 'Invalid pseudo for event';
  end if;

  if not exists (select 1 from public.players p where p.pseudo = new.pseudo) then
    raise exception 'Unknown player pseudo';
  end if;

  select t.type into v_treasure_type
  from public.treasures t
  where t.id = new.treasure_id;

  if v_treasure_type is null then
    raise exception 'Unknown treasure';
  end if;

  if new.treasure_type is null then
    new.treasure_type := v_treasure_type;
  elsif new.treasure_type <> v_treasure_type then
    raise exception 'Treasure type mismatch';
  end if;

  if new.duration_sec is null or new.duration_sec < 0 then
    raise exception 'Invalid duration_sec';
  end if;

  return new;
end;
$$;

create or replace function public.guard_player_stats_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if current_setting('u3dq.internal_stats_sync', true) = '1' then
    return new;
  end if;

  if not public.is_admin() then
    if new.score is distinct from old.score
       or new.found_count is distinct from old.found_count then
      raise exception 'score/found_count are server-managed';
    end if;
  end if;

  return new;
end;
$$;

create or replace function public.recompute_player_stats(p_player text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform set_config('u3dq.internal_stats_sync', '1', true);

  update public.players p
  set found_count = agg.cnt,
      score = agg.total
  from (
    select coalesce(count(*)::int, 0) as cnt,
           coalesce(sum(e.duration_sec)::bigint, 0) as total
    from public.events e
    where e.pseudo = p_player
  ) agg
  where p.pseudo = p_player;
end;
$$;

create or replace function public.sync_player_stats_from_events()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    perform public.recompute_player_stats(new.pseudo);
    return new;
  elsif tg_op = 'DELETE' then
    perform public.recompute_player_stats(old.pseudo);
    return old;
  else
    if new.pseudo is distinct from old.pseudo then
      perform public.recompute_player_stats(old.pseudo);
    end if;
    perform public.recompute_player_stats(new.pseudo);
    return new;
  end if;
end;
$$;

drop trigger if exists trg_events_validate_insert on events;
create trigger trg_events_validate_insert
before insert on events
for each row
execute function public.validate_event_insert();

drop trigger if exists trg_players_guard_stats_update on players;
create trigger trg_players_guard_stats_update
before update on players
for each row
execute function public.guard_player_stats_update();

drop trigger if exists trg_events_sync_player_stats on events;
create trigger trg_events_sync_player_stats
after insert or update of pseudo, duration_sec or delete on events
for each row
execute function public.sync_player_stats_from_events();

-- 7) Storage hardening for admin uploads in bucket photos
drop policy if exists photos_admin_select on storage.objects;
drop policy if exists photos_admin_insert on storage.objects;
drop policy if exists photos_admin_update on storage.objects;
drop policy if exists photos_admin_delete on storage.objects;

create policy photos_admin_select on storage.objects
for select to authenticated
using (bucket_id = 'photos' and public.is_admin());

create policy photos_admin_insert on storage.objects
for insert to authenticated
with check (bucket_id = 'photos' and public.is_admin());

create policy photos_admin_update on storage.objects
for update to authenticated
using (bucket_id = 'photos' and public.is_admin())
with check (bucket_id = 'photos' and public.is_admin());

create policy photos_admin_delete on storage.objects
for delete to authenticated
using (bucket_id = 'photos' and public.is_admin());

commit;

-- Post-deploy checklist:
-- 1) Create an admin user in Supabase Auth (email/password).
-- 2) Insert that user's UUID into admin_users.
--    Example:
--    insert into admin_users(user_id)
--    values ('00000000-0000-0000-0000-000000000000');
-- 3) Test admin login in admin.html.
