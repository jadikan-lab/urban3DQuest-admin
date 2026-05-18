-- Urban3DQuest — migration: activation timestamp for treasure deposits
-- Used to start Flash duration only when the admin validates the deposit.

begin;

alter table if exists treasures
  add column if not exists activated_at timestamptz;

commit;