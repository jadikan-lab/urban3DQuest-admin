# STG/PROD Parity Runbook

Goal: keep STG and PROD schema equivalent for Urban3DQuest.

## Repository scope
- Code repositories in use: `urban3DQuest` (game) and `urban3DQuest-admin` (admin).
- There is no separate staging code repository.
- STG is a Supabase environment only.

## Why drift happens
- STG and PROD are two distinct Supabase projects.
- SQL changes are not auto-applied across environments.
- A migration can be committed in Git but still missing in one DB.

## Mandatory workflow (every schema change)
1. Add a migration file in this repository.
2. Until launch phase: apply and validate on PROD first.
3. After launch phase: copy/sync current PROD state to STG, then iterate on STG before promoting to PROD.
4. Re-check parity with the SQL checks below.

## Minimal fix for current drift (activated_at)
Run in SQL Editor on STG, then PROD:

```sql
begin;

alter table if exists treasures
  add column if not exists activated_at timestamptz;

commit;
```

## Parity checks (run on STG and PROD)

### Check `treasures.activated_at`
```sql
select column_name, data_type
from information_schema.columns
where table_schema = 'public'
  and table_name = 'treasures'
  and column_name = 'activated_at';
```

### Check isolated auth table
```sql
select column_name
from information_schema.columns
where table_schema = 'public'
  and table_name = 'player_auth'
  and column_name in ('password_hash', 'session_token')
order by column_name;
```

### Check server-side score trigger
```sql
select trigger_name, event_object_table
from information_schema.triggers
where trigger_schema = 'public'
  and event_object_table in ('events', 'players')
  and trigger_name in (
    'trg_events_validate_insert',
    'trg_events_sync_player_stats',
    'trg_players_guard_stats_update'
  )
order by trigger_name;
```

## Notes
- The game currently includes a temporary client fallback if `activated_at` is missing.
- Keep this fallback only as a safety net; parity should come from DB migrations.
