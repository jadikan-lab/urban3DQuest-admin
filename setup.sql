-- ══════════════════════════════════════════════════════
-- Urban3DQuest — Supabase setup
-- Coller dans : Supabase Dashboard > SQL Editor > Run
-- ══════════════════════════════════════════════════════

-- Nettoyage (si re-run)
drop table if exists events cascade;
drop table if exists players cascade;
drop table if exists treasures cascade;
drop table if exists config cascade;

-- ── Trésors ──────────────────────────────────────────
create table treasures (
  id           text primary key,
  type         text not null default 'fixed', -- 'fixed' | 'unique'
  lat          double precision not null,
  lng          double precision not null,
  placed_at    timestamptz default now(),
  label        text default '',
  hint         text default '',
  visible      boolean default true,
  photo_url    text default '',
  found_by     text default '',   -- fixed: pseudos CSV | unique: pseudo unique
  found_at     timestamptz,
  quest        text default ''   -- nom de la quête (filtre admin/joueur)
);

-- ── Joueurs ───────────────────────────────────────────
create table players (
  pseudo         text primary key,
  joined_at      timestamptz default now(),
  score          bigint default 0,      -- somme des durées en secondes
  found_count    integer default 0,
  password_hash  text default '',       -- SHA-256 hex (hashed client-side)
  session_token  text                   -- UUID; NULL = logged out; replaced on each new login
);

-- ── Log événements ────────────────────────────────────
create table events (
  id            bigserial primary key,
  created_at    timestamptz default now(),
  pseudo        text,
  treasure_id   text references treasures(id) on delete set null,
  treasure_type text,
  duration_sec  bigint
);

-- ── Config ────────────────────────────────────────────
create table config (
  key   text primary key,
  value text
);

insert into config (key, value) values
  ('proximityRadius', '100'),
  ('gameActive',      'true');

-- ── Désactiver RLS (event privé) ─────────────────────
alter table treasures disable row level security;
alter table players   disable row level security;
alter table events    disable row level security;
alter table config    disable row level security;

-- ── Realtime (leaderboard live) ───────────────────────
alter publication supabase_realtime add table players;
alter publication supabase_realtime add table events;

-- ══════════════════════════════════════════════════════
-- Storage bucket (à faire dans le dashboard Supabase) :
--   Storage > New bucket > Nom: "photos" > Public: ON
-- ══════════════════════════════════════════════════════
