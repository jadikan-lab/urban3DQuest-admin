-- ══════════════════════════════════════════════════════════════════════
-- Urban3DQuest — PROD init complet
-- À exécuter UNE SEULE FOIS dans : Supabase PROD > SQL Editor > Run
-- Idempotent : safe à rejouer si besoin (IF NOT EXISTS / OR REPLACE)
-- ══════════════════════════════════════════════════════════════════════

begin;

-- ── 1) Tables (créées seulement si elles n'existent pas) ──────────────

create table if not exists treasures (
  id           text primary key,
  type         text not null default 'fixed',
  lat          double precision not null,
  lng          double precision not null,
  placed_at    timestamptz default now(),
  label        text default '',
  hint         text default '',
  visible      boolean default true,
  photo_url    text default '',
  found_by     text default '',
  found_at     timestamptz,
  quest        text default ''
);

create table if not exists players (
  pseudo         text primary key,
  joined_at      timestamptz default now(),
  score          bigint default 0,
  found_count    integer default 0,
  password_hash  text default '',
  session_token  text
);

create table if not exists events (
  id            bigserial primary key,
  created_at    timestamptz default now(),
  pseudo        text,
  treasure_id   text references treasures(id) on delete set null,
  treasure_type text,
  duration_sec  bigint
);

create table if not exists config (
  key   text primary key,
  value text
);

-- Config par défaut (ne remplace pas les valeurs existantes)
insert into config (key, value) values
  ('proximityRadius', '100'),
  ('gameActive',      'true')
on conflict (key) do nothing;

-- ── 2) Table admin_users ──────────────────────────────────────────────

create table if not exists admin_users (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table admin_users enable row level security;

drop policy if exists admin_users_self_read on admin_users;
create policy admin_users_self_read on admin_users
for select to authenticated
using (auth.uid() = user_id);

-- ── 3) Fonction is_admin() ────────────────────────────────────────────

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.admin_users a where a.user_id = auth.uid()
  );
$$;

grant execute on function public.is_admin() to anon, authenticated;

-- ── 4) Activer RLS sur les tables de jeu ─────────────────────────────

alter table treasures enable row level security;
alter table players   enable row level security;
alter table events    enable row level security;
alter table config    enable row level security;

-- ── 5) Nettoyer les anciennes policies (idempotent) ───────────────────

drop policy if exists treasures_read_all     on treasures;
drop policy if exists treasures_update_found on treasures;
drop policy if exists treasures_admin_all    on treasures;

drop policy if exists players_read_all    on players;
drop policy if exists players_insert_self on players;
drop policy if exists players_update_self on players;
drop policy if exists players_admin_all   on players;

drop policy if exists events_read_all   on events;
drop policy if exists events_insert_all on events;
drop policy if exists events_admin_all  on events;

drop policy if exists config_read_all  on config;
drop policy if exists config_admin_all on config;

-- ── 6) Policies lecture publique (app joueur) ─────────────────────────

create policy treasures_read_all on treasures
  for select to anon, authenticated using (true);

create policy players_read_all on players
  for select to anon, authenticated using (true);

create policy events_read_all on events
  for select to anon, authenticated using (true);

create policy config_read_all on config
  for select to anon, authenticated using (true);

-- ── 7) Policies écriture joueurs (limitées) ───────────────────────────

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

-- Claim déclic : protégé côté app par update ... eq('found_by','')
create policy treasures_update_found on treasures
  for update to anon, authenticated
  using (true)
  with check (found_by is not null);

-- ── 8) Policies admin (toutes opérations) ────────────────────────────

create policy treasures_admin_all on treasures
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy players_admin_all on players
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy events_admin_all on events
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy config_admin_all on config
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- ── 9) Minimal anti-tampering safeguards for gameplay data ───────────

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

-- ── 10) Storage bucket photos ─────────────────────────────────────────

-- Créer le bucket s'il n'existe pas (pas de "create if not exists" en SQL
-- pour storage, le faire via Dashboard Storage > New bucket : "photos", public)

drop policy if exists photos_admin_select on storage.objects;
drop policy if exists photos_admin_insert on storage.objects;
drop policy if exists photos_admin_update on storage.objects;
drop policy if exists photos_admin_delete on storage.objects;
drop policy if exists photos_public_read  on storage.objects;

create policy photos_public_read on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'photos');

create policy photos_admin_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'photos' and public.is_admin());

create policy photos_admin_update on storage.objects
  for update to authenticated
  using  (bucket_id = 'photos' and public.is_admin())
  with check (bucket_id = 'photos' and public.is_admin());

create policy photos_admin_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'photos' and public.is_admin());

commit;

-- ══════════════════════════════════════════════════════════════════════
-- ÉTAPE FINALE (après avoir exécuté ce script) :
--
-- 1. Dans Supabase PROD > Authentication > Users :
--    créer un compte email/mot de passe pour l'admin.
--
-- 2. Copier l'UUID du compte créé, puis exécuter :
--
--    INSERT INTO admin_users (user_id)
--    VALUES ('<uuid-du-compte-admin-prod>')
--    ON CONFLICT DO NOTHING;
--
-- 3. Dans Supabase PROD > Storage : créer le bucket "photos" (public).
--
-- 4. Tester admin.html en basculant sur PROD.
-- ══════════════════════════════════════════════════════════════════════
