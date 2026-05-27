# STG/PROD Parity Runbook

Goal: keep STG and PROD schema equivalent for Urban3DQuest.

## Policy update
- Version: ENV-POLICY-2026-05-27-v1
- Effective date: 2026-05-27
- Decision: work in PROD by default until explicit contrary instruction.
- STG status: paused.
- When STG is paused, no schema/code validation is required on STG.
- Resume rule: STG can be reactivated only with an explicit instruction, recorded with a new policy version/date.

## Current environment status (2026-05-26)
- Current team observation: STG and PROD may not be differentiated at the Supabase project level.
- If there is only one active Supabase project, apply each migration once on that project and run verification queries on that same project.
- If a separate STG project is reintroduced later, this runbook immediately goes back to dual-environment apply and parity checks.

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
2. Apply and validate on PROD.
3. If STG is explicitly reactivated, sync from PROD first, then run parity checks below.
4. Re-check parity only when STG is active.

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
