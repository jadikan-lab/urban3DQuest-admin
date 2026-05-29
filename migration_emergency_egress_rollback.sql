-- Emergency egress rollback (temporary)
-- Use this to undo migration_emergency_egress_lockdown.sql.
-- Run in Supabase SQL Editor on PROD first, then STG if needed.

begin;

-- 0) Remove temporary emergency policies
--    (drop first to avoid duplicate-policy errors)
drop policy if exists config_read_whitelist on public.config;
drop policy if exists treasures_read_visible_only on public.treasures;
drop policy if exists players_read_light on public.players;

-- 1) Restore original broad public read policies used by the player app
create policy config_read_all on public.config
for select to anon, authenticated
using (true);

create policy treasures_read_all on public.treasures
for select to anon, authenticated
using (true);

create policy players_read_all on public.players
for select to anon, authenticated
using (true);

create policy events_read_all on public.events
for select to anon, authenticated
using (true);

-- 2) Optional: restore public photo access if you had disabled it manually
-- create policy photos_public_read on storage.objects
-- for select to public
-- using (bucket_id = 'photos');

commit;

-- Quick verification queries (run after apply):
-- select policyname, tablename, permissive, cmd, roles from pg_policies
--   where schemaname = 'public' and tablename in ('config','treasures','players','events')
--   order by tablename, policyname;
