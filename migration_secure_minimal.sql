-- Urban3DQuest - migration de securisation minimale (sans usine a gaz)
-- A executer sur une base existante (STG puis PROD)

begin;

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

-- Recalcule l'historique existant une fois
update public.players p
set found_count = agg.cnt,
    score = agg.total
from (
  select e.pseudo,
         count(*)::int as cnt,
         coalesce(sum(e.duration_sec)::bigint, 0) as total
  from public.events e
  group by e.pseudo
) agg
where p.pseudo = agg.pseudo;

update public.players
set found_count = 0,
    score = 0
where pseudo not in (select distinct pseudo from public.events);

commit;
