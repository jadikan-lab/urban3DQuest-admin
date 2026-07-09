-- Secure capture RPC hardening: duration anchor must come from latest admin unmask only.
-- Removes placed_at fallback to enforce activated_at as the sole anchor.
-- Apply in PROD then STG.

create or replace function public.process_find_secure(
  p_pseudo text,
  p_session_token text,
  p_treasure_id text,
  p_player_lat double precision,
  p_player_lng double precision,
  p_proximity_m integer default 100
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_t record;
  v_now timestamptz := now();
  v_ref_time timestamptz;
  v_game_start_txt text;
  v_game_start timestamptz;
  v_found_list text[];
  v_already_found boolean := false;
  v_new_found_by text;
  v_duration_sec bigint;
  v_distance_m numeric;
  v_session_ok boolean := true;
  v_event_id bigint;
  v_prev_found_by text;
  v_prev_found_at timestamptz;
  v_proximity_m integer;
begin
  v_proximity_m := greatest(10, coalesce(p_proximity_m, 100));

  if p_pseudo is null or btrim(p_pseudo) = '' then
    begin
      if to_regclass('public.scan_attempts') is not null then
        insert into public.scan_attempts (
          pseudo, treasure_id, status, proximity_m, player_lat, player_lng
        ) values (
          nullif(btrim(p_pseudo), ''), p_treasure_id, 'invalid_pseudo', v_proximity_m, p_player_lat, p_player_lng
        );
      end if;
    exception when others then
      null;
    end;
    return jsonb_build_object('status', 'invalid_pseudo');
  end if;

  -- Session validation when server function exists (prod/stg auth split path).
  if p_session_token is not null and btrim(p_session_token) <> '' and to_regprocedure('public.validate_player_session(text,text)') is not null then
    begin
      select coalesce((public.validate_player_session(p_pseudo, p_session_token)->>'valid')::boolean, false)
        into v_session_ok;
    exception when others then
      v_session_ok := false;
    end;
    if not v_session_ok then
      begin
        if to_regclass('public.scan_attempts') is not null then
          insert into public.scan_attempts (
            pseudo, treasure_id, status, proximity_m, player_lat, player_lng
          ) values (
            p_pseudo, p_treasure_id, 'invalid_session', v_proximity_m, p_player_lat, p_player_lng
          );
        end if;
      exception when others then
        null;
      end;
      return jsonb_build_object('status', 'invalid_session');
    end if;
  end if;

  select *
    into v_t
    from public.treasures
   where id = p_treasure_id
   for update;

  if not found then
    begin
      if to_regclass('public.scan_attempts') is not null then
        insert into public.scan_attempts (
          pseudo, treasure_id, status, proximity_m, player_lat, player_lng
        ) values (
          p_pseudo, p_treasure_id, 'not_found', v_proximity_m, p_player_lat, p_player_lng
        );
      end if;
    exception when others then
      null;
    end;
    return jsonb_build_object('status', 'not_found');
  end if;

  if not coalesce(v_t.visible, false) then
    begin
      if to_regclass('public.scan_attempts') is not null then
        insert into public.scan_attempts (
          pseudo, treasure_id, treasure_type, status, proximity_m, player_lat, player_lng
        ) values (
          p_pseudo, v_t.id, v_t.type, 'hidden', v_proximity_m, p_player_lat, p_player_lng
        );
      end if;
    exception when others then
      null;
    end;
    return jsonb_build_object('status', 'hidden');
  end if;

  if p_player_lat is null or p_player_lng is null then
    begin
      if to_regclass('public.scan_attempts') is not null then
        insert into public.scan_attempts (
          pseudo, treasure_id, treasure_type, status, proximity_m, player_lat, player_lng
        ) values (
          p_pseudo, v_t.id, v_t.type, 'no_gps', v_proximity_m, p_player_lat, p_player_lng
        );
      end if;
    exception when others then
      null;
    end;
    return jsonb_build_object('status', 'no_gps');
  end if;

  v_distance_m := 6371000.0 * 2.0 * asin(
    sqrt(
      power(sin(radians((coalesce(v_t.lat, 0) - p_player_lat) / 2.0)), 2) +
      cos(radians(p_player_lat)) * cos(radians(coalesce(v_t.lat, 0))) *
      power(sin(radians((coalesce(v_t.lng, 0) - p_player_lng) / 2.0)), 2)
    )
  );

  if v_distance_m > v_proximity_m then
    begin
      if to_regclass('public.scan_attempts') is not null then
        insert into public.scan_attempts (
          pseudo, treasure_id, treasure_type, status, distance_m, proximity_m, player_lat, player_lng
        ) values (
          p_pseudo, v_t.id, v_t.type, 'too_far', round(v_distance_m)::integer, v_proximity_m, p_player_lat, p_player_lng
        );
      end if;
    exception when others then
      null;
    end;
    return jsonb_build_object(
      'status', 'too_far',
      'distance_m', round(v_distance_m)
    );
  end if;

  v_found_list := array_remove(string_to_array(coalesce(v_t.found_by, ''), ','), '');
  if array_length(v_found_list, 1) is not null then
    v_already_found := p_pseudo = any(v_found_list);
  end if;

  if v_already_found then
    begin
      if to_regclass('public.scan_attempts') is not null then
        insert into public.scan_attempts (
          pseudo, treasure_id, treasure_type, status, distance_m, proximity_m, player_lat, player_lng
        ) values (
          p_pseudo, v_t.id, v_t.type, 'already', round(v_distance_m)::integer, v_proximity_m, p_player_lat, p_player_lng
        );
      end if;
    exception when others then
      null;
    end;
    return jsonb_build_object('status', 'already');
  end if;

  if v_t.type = 'unique' and coalesce(v_t.found_by, '') <> '' then
    begin
      if to_regclass('public.scan_attempts') is not null then
        insert into public.scan_attempts (
          pseudo, treasure_id, treasure_type, status, distance_m, proximity_m, player_lat, player_lng
        ) values (
          p_pseudo, v_t.id, v_t.type, 'taken', round(v_distance_m)::integer, v_proximity_m, p_player_lat, p_player_lng
        );
      end if;
    exception when others then
      null;
    end;
    return jsonb_build_object('status', 'taken', 'found_by', v_t.found_by);
  end if;

  select value into v_game_start_txt from public.config where key = 'gameStart';
  begin
    if v_game_start_txt is not null and btrim(v_game_start_txt) <> '' then
      v_game_start := v_game_start_txt::timestamptz;
    end if;
  exception when others then
    v_game_start := null;
  end;

  -- Strict business rule: only latest admin unmask timestamp anchors the duration.
  v_ref_time := coalesce(v_t.activated_at, v_now);
  if v_game_start is not null and v_game_start > v_ref_time then
    v_ref_time := v_game_start;
  end if;

  v_duration_sec := greatest(0, round(extract(epoch from (v_now - v_ref_time))))::bigint;

  if v_t.type = 'unique' then
    v_new_found_by := p_pseudo;
  else
    v_new_found_by := case when coalesce(v_t.found_by, '') = '' then p_pseudo else v_t.found_by || ',' || p_pseudo end;
  end if;

  v_prev_found_by := coalesce(v_t.found_by, '');
  v_prev_found_at := v_t.found_at;

  begin
    -- Ensure player row exists so event trigger validation cannot fail for known sessions.
    insert into public.players (pseudo)
    values (p_pseudo)
    on conflict (pseudo) do nothing;

    update public.treasures
       set found_by = v_new_found_by,
           found_at = v_now
     where id = v_t.id;

    insert into public.events (pseudo, treasure_id, treasure_type, duration_sec, created_at)
    values (p_pseudo, v_t.id, v_t.type, v_duration_sec, v_now)
    on conflict (pseudo, treasure_id) do nothing
    returning id into v_event_id;
  exception when others then
    update public.treasures
       set found_by = v_prev_found_by,
           found_at = v_prev_found_at
     where id = v_t.id;

    begin
      if to_regclass('public.scan_attempts') is not null then
        insert into public.scan_attempts (
          pseudo, treasure_id, treasure_type, status, distance_m, proximity_m, player_lat, player_lng
        ) values (
          p_pseudo, v_t.id, v_t.type, 'event_error', round(v_distance_m)::integer, v_proximity_m, p_player_lat, p_player_lng
        );
      end if;
    exception when others then
      null;
    end;

    return jsonb_build_object('status', 'event_error');
  end;

  if v_event_id is null then
    begin
      if to_regclass('public.scan_attempts') is not null then
        insert into public.scan_attempts (
          pseudo, treasure_id, treasure_type, status, distance_m, proximity_m, player_lat, player_lng
        ) values (
          p_pseudo, v_t.id, v_t.type, 'already', round(v_distance_m)::integer, v_proximity_m, p_player_lat, p_player_lng
        );
      end if;
    exception when others then
      null;
    end;
    return jsonb_build_object('status', 'already');
  end if;

  begin
    if to_regclass('public.scan_attempts') is not null then
      insert into public.scan_attempts (
        pseudo, treasure_id, treasure_type, status, distance_m, proximity_m, player_lat, player_lng
      ) values (
        p_pseudo, v_t.id, v_t.type, 'success', round(v_distance_m)::integer, v_proximity_m, p_player_lat, p_player_lng
      );
    end if;
  exception when others then
    null;
  end;

  return jsonb_build_object(
    'status', 'success',
    'treasure_id', v_t.id,
    'treasure_type', v_t.type,
    'duration_sec', v_duration_sec,
    'distance_m', round(v_distance_m)
  );
end;
$$;

grant execute on function public.process_find_secure(text, text, text, double precision, double precision, integer) to anon, authenticated;
