-- Urban3DQuest - migration: isolate player secrets from public player data
-- Apply on existing STG/PROD databases after migration_add_auth.sql.

begin;

create table if not exists public.player_auth (
  pseudo text primary key references public.players(pseudo) on delete cascade,
  password_hash text not null default '',
  session_token text
);

alter table public.player_auth enable row level security;

revoke all on public.player_auth from anon, authenticated, public;

insert into public.player_auth (pseudo, password_hash, session_token)
select pseudo,
       coalesce(password_hash, ''),
       session_token
from public.players
on conflict (pseudo) do update
set password_hash = excluded.password_hash,
    session_token = excluded.session_token;

drop policy if exists players_read_all on public.players;
drop policy if exists players_update_self on public.players;

revoke all on public.players from anon, authenticated, public;
grant select (pseudo, joined_at, score, found_count) on public.players to anon, authenticated;
grant insert (pseudo, joined_at, score, found_count) on public.players to anon, authenticated;

alter table public.players
  alter column score set default 0,
  alter column found_count set default 0,
  alter column password_hash drop default,
  alter column session_token drop default;

alter table public.players
  drop column if exists password_hash,
  drop column if exists session_token;

create or replace function public.authenticate_player(
  p_pseudo text,
  p_password_hash text,
  p_session_token text,
  p_is_stg boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_password_hash text;
  v_score bigint;
  v_found_count integer;
begin
  insert into public.players (pseudo, joined_at, score, found_count)
  values (p_pseudo, now(), 0, 0)
  on conflict (pseudo) do nothing;

  insert into public.player_auth (pseudo, password_hash, session_token)
  values (
    p_pseudo,
    case when p_is_stg then '' else coalesce(p_password_hash, '') end,
    p_session_token
  )
  on conflict (pseudo) do nothing;

  select pa.password_hash
  into v_password_hash
  from public.player_auth pa
  where pa.pseudo = p_pseudo;

  if not p_is_stg and coalesce(v_password_hash, '') <> '' and v_password_hash <> coalesce(p_password_hash, '') then
    return jsonb_build_object('ok', false, 'message', 'Mot de passe incorrect.');
  end if;

  if not p_is_stg and coalesce(v_password_hash, '') = '' then
    update public.player_auth
    set password_hash = coalesce(p_password_hash, '')
    where pseudo = p_pseudo;
  end if;

  update public.player_auth
  set session_token = p_session_token
  where pseudo = p_pseudo;

  select p.score, p.found_count
  into v_score, v_found_count
  from public.players p
  where p.pseudo = p_pseudo;

  return jsonb_build_object(
    'ok', true,
    'message', null,
    'score', coalesce(v_score, 0),
    'found_count', coalesce(v_found_count, 0)
  );
end;
$$;

create or replace function public.validate_player_session(
  p_pseudo text,
  p_session_token text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session_token text;
  v_score bigint;
  v_found_count integer;
begin
  select pa.session_token
  into v_session_token
  from public.player_auth pa
  where pa.pseudo = p_pseudo;

  if not found or v_session_token is distinct from p_session_token then
    return jsonb_build_object('valid', false);
  end if;

  select p.score, p.found_count
  into v_score, v_found_count
  from public.players p
  where p.pseudo = p_pseudo;

  return jsonb_build_object(
    'valid', true,
    'score', coalesce(v_score, 0),
    'found_count', coalesce(v_found_count, 0)
  );
end;
$$;

create or replace function public.clear_player_session(p_pseudo text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.player_auth
  set session_token = null
  where pseudo = p_pseudo;
end;
$$;

grant execute on function public.authenticate_player(text, text, text, boolean) to anon, authenticated;
grant execute on function public.validate_player_session(text, text) to anon, authenticated;
grant execute on function public.clear_player_session(text) to anon, authenticated;

commit;