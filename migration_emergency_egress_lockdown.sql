-- Emergency egress lockdown (temporary)
-- Run in Supabase SQL Editor on PROD first, then STG.
-- Goal: reduce anonymous data egress quickly while keeping core gameplay mostly operational.

begin;

-- 0) Teaser OFF at config level
insert into public.config (key, value)
values ('teaserEnabled', 'false')
on conflict (key) do update set value = excluded.value;

-- 1) Lock down public reads on config to a strict whitelist
--    (prevents dumping full config table from anon key)
drop policy if exists config_read_all on public.config;
create policy config_read_whitelist on public.config
for select to anon, authenticated
using (
  key in (
    'proximityRadius',
    'fixedTotal',
    'modeMap',
    'modeCompass',
    'gameActive',
    'mapCenter',
    'gameStart',
    'gameCode',
    'guestLandingUrl',
    'activeQuests',
    'activeQuest',
    'qrGuideFlashUrl',
    'qrGuideFixedUrl',
    'qrGuideGenericUrl'
  )
);

-- 2) Keep treasures readable only when visible=true for anon/authenticated
--    (limits accidental reads of hidden content)
drop policy if exists treasures_read_all on public.treasures;
create policy treasures_read_visible_only on public.treasures
for select to anon, authenticated
using (visible = true);

-- 3) Disable public read on events (largest egress risk)
--    NOTE: this temporarily degrades leaderboard details that depend on events.
drop policy if exists events_read_all on public.events;

-- 4) Keep players read policy (lightweight) for basic ranking/profile displays.
--    If abuse continues, comment-out this section and re-run to remove policy.
drop policy if exists players_read_all on public.players;
create policy players_read_light on public.players
for select to anon, authenticated
using (true);

-- 5) Optional hard stop for image egress from storage bucket 'photos'
--    UNCOMMENT ONLY if egress is still critical and you accept broken public images.
-- drop policy if exists photos_public_read on storage.objects;

commit;

-- Quick verification queries (run after apply):
-- select key, value from public.config where key = 'teaserEnabled';
-- select policyname, tablename, permissive, cmd, roles from pg_policies
--   where schemaname = 'public' and tablename in ('config','treasures','players','events')
--   order by tablename, policyname;
