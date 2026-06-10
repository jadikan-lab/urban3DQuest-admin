-- Add flag for hidden solo QR treasures (not shown to players on map/progression)
alter table public.treasures
  add column if not exists solo_hidden boolean not null default false;

comment on column public.treasures.solo_hidden is
  'When true, treasure stays administrable but is hidden from player map/progression (solo QR flow).';
