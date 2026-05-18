-- ══════════════════════════════════════════════════════════════════════
-- Urban3DQuest — Migration : trigger de calcul de score côté serveur
-- À exécuter sur les bases créées avec setup.sql (sans RLS) qui n'ont
-- pas encore le trigger. Les bases créées via setup_prod_init.sql ou
-- setup_secure_rls.sql ont déjà ces fonctions — ce script est idempotent.
-- ══════════════════════════════════════════════════════════════════════

-- ── 1) Unicité event par (pseudo, treasure_id) ────────────────────────
create unique index if not exists events_unique_pseudo_treasure
on events (pseudo, treasure_id);

-- ── 2) Fonction utilitaire interne ────────────────────────────────────
create or replace function public.recompute_player_stats(p_player text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.players p
  set found_count = agg.cnt,
      score       = agg.total
  from (
    select coalesce(count(*)::int, 0)          as cnt,
           coalesce(sum(e.duration_sec)::bigint, 0) as total
    from public.events e
    where e.pseudo = p_player
  ) agg
  where p.pseudo = p_player;
end;
$$;

-- ── 3) Fonction trigger ───────────────────────────────────────────────
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

-- ── 4) Attacher le trigger ────────────────────────────────────────────
drop trigger if exists trg_events_sync_player_stats on events;
create trigger trg_events_sync_player_stats
after insert or update of pseudo, duration_sec or delete on events
for each row
execute function public.sync_player_stats_from_events();

-- ── 5) Recalcul rétroactif pour tous les joueurs existants ────────────
do $$
declare r record;
begin
  for r in select distinct pseudo from events where pseudo is not null loop
    perform public.recompute_player_stats(r.pseudo);
  end loop;
end;
$$;

-- ══════════════════════════════════════════════════════════════════════
-- Après cette migration, les colonnes players.score et players.found_count
-- sont recalculées automatiquement à chaque INSERT/UPDATE/DELETE sur events.
-- Le client (find.js) lit ces valeurs depuis players après son INSERT.
-- ══════════════════════════════════════════════════════════════════════
