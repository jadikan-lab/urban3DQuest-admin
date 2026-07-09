-- Log QR link opens even when no gameplay validation occurs.
-- Writes into public.scan_attempts with qr_open* statuses.
-- Apply in PROD then STG.

create or replace function public.log_qr_open(
  p_treasure_id text,
  p_pseudo text default null,
  p_scan_kind text default 'found'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id text := nullif(btrim(p_treasure_id), '');
  v_pseudo text := nullif(btrim(p_pseudo), '');
  v_kind text := lower(coalesce(nullif(btrim(p_scan_kind), ''), 'found'));
  v_status text;
  v_t record;
begin
  if to_regclass('public.scan_attempts') is null then
    return jsonb_build_object('status', 'scan_attempts_missing');
  end if;

  if v_kind not in ('found', 'checkin') then
    v_kind := 'found';
  end if;

  v_status := case when v_kind = 'checkin' then 'qr_open_checkin' else 'qr_open' end;

  if v_id is not null then
    select id, type
      into v_t
      from public.treasures
     where id = v_id
     limit 1;
  end if;

  if v_t.id is null then
    insert into public.scan_attempts (pseudo, treasure_id, treasure_type, status)
    values (v_pseudo, null, null, v_status || '_unknown');

    return jsonb_build_object(
      'status', v_status || '_unknown',
      'treasure_id', v_id
    );
  end if;

  insert into public.scan_attempts (pseudo, treasure_id, treasure_type, status)
  values (v_pseudo, v_t.id, v_t.type, v_status);

  return jsonb_build_object(
    'status', v_status,
    'treasure_id', v_t.id,
    'treasure_type', v_t.type
  );
end;
$$;

grant execute on function public.log_qr_open(text, text, text) to anon, authenticated;
