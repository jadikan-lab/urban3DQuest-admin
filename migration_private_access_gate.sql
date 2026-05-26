-- Urban3DQuest - migration: optional private tester allowlist gate
-- Blocks login/session validation when config.privateAccessEnabled=true
-- and pseudo is not in config.privateAllowedPseudos.

begin;

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
  v_private_enabled boolean := false;
  v_allowed_raw text := '';
  v_is_allowed boolean := false;
begin
  select (coalesce(value, '') = 'true')
  into v_private_enabled
  from public.config
  where key = 'privateAccessEnabled';

  if coalesce(v_private_enabled, false) then
    select coalesce(value, '')
    into v_allowed_raw
    from public.config
    where key = 'privateAllowedPseudos';

    select exists (
      select 1
      from regexp_split_to_table(v_allowed_raw, '[\\s,;]+') as allowed(pseudo)
      where upper(trim(allowed.pseudo)) = upper(trim(coalesce(p_pseudo, '')))
    )
    into v_is_allowed;

    if not v_is_allowed then
      return jsonb_build_object('ok', false, 'message', 'Acces prive active : pseudo non autorise.');
    end if;
  end if;

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
  v_private_enabled boolean := false;
  v_allowed_raw text := '';
  v_is_allowed boolean := false;
begin
  select (coalesce(value, '') = 'true')
  into v_private_enabled
  from public.config
  where key = 'privateAccessEnabled';

  if coalesce(v_private_enabled, false) then
    select coalesce(value, '')
    into v_allowed_raw
    from public.config
    where key = 'privateAllowedPseudos';

    select exists (
      select 1
      from regexp_split_to_table(v_allowed_raw, '[\\s,;]+') as allowed(pseudo)
      where upper(trim(allowed.pseudo)) = upper(trim(coalesce(p_pseudo, '')))
    )
    into v_is_allowed;

    if not v_is_allowed then
      return jsonb_build_object('valid', false);
    end if;
  end if;

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

grant execute on function public.authenticate_player(text, text, text, boolean) to anon, authenticated;
grant execute on function public.validate_player_session(text, text) to anon, authenticated;

commit;
