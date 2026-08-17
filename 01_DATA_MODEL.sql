-- ============================================================================
-- TERRASTEP — Data Model  (Postgres 15 / Supabase)
-- Run in the Supabase SQL editor, top to bottom.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. EXTENSIONS
-- ---------------------------------------------------------------------------
create extension if not exists postgis      with schema extensions;
create extension if not exists pg_cron;
create extension if not exists h3           with schema extensions;  -- optional
create extension if not exists h3_postgis   with schema extensions;  -- optional

-- NOTE ON h3-pg: Supabase ships the `h3` extension on most regions, but it is
-- NOT guaranteed. Everything below is written so that h3-pg is OPTIONAL — the
-- client computes cell IDs and the server validates using stored lat/lng plus
-- cheap arithmetic. If h3-pg IS available, uncomment the stronger geometric
-- checks marked  -- [H3-PG]  in 02_CLAIM_ENGINE.sql.
-- Verify with:  select * from pg_available_extensions where name like 'h3%';


-- ---------------------------------------------------------------------------
-- 1. GAME CONFIG  — tune balance without shipping an app update
-- ---------------------------------------------------------------------------
create table public.game_config (
  key         text primary key,
  value       numeric not null,
  description text
);

insert into public.game_config (key, value, description) values
  ('h3_resolution',        9,    'Ownership grid resolution'),
  ('claim_min_steps',      120,  'Min steps inside a cell to claim'),
  ('claim_min_distance_m', 80,   'Min metres travelled inside cell'),
  ('claim_min_dwell_s',    90,   'Min seconds inside cell'),
  ('claim_min_fixes',      5,    'Min distinct GPS fixes inside cell'),
  ('effort_step_weight',   1.00, null),
  ('effort_dist_weight',   0.35, null),
  ('effort_dwell_weight',  0.05, null),
  ('max_effort_per_visit', 600,  'Anti-grind cap per sync per cell'),
  ('decay_half_life_days', 7,    'Influence halves every N days'),
  ('neutral_floor',        100,  'Below this, cell reverts to neutral'),
  ('takeover_multiplier',  1.15, 'Hysteresis: must beat owner by 15%'),
  ('takeover_flat_margin', 50,   'Hysteresis: ... plus a flat margin'),
  ('max_speed_mps',        8.0,  'Sustained speed above this = rejected'),
  ('max_accuracy_m',       35,   'GPS fixes worse than this are dropped'),
  ('max_cells_per_hour',   50,   null),
  ('max_cells_per_day',    200,  null),
  ('realtime_parent_res',  5,    'Resolution of the realtime broadcast channel');

alter table public.game_config enable row level security;
create policy "config readable by all" on public.game_config for select using (true);

-- Cached accessor (STABLE so the planner can hoist it out of loops)
create or replace function public.cfg(p_key text)
returns numeric language sql stable parallel safe as $$
  select value from public.game_config where key = p_key;
$$;


-- ---------------------------------------------------------------------------
-- 2. PROFILES
-- ---------------------------------------------------------------------------
create table public.profiles (
  id                uuid primary key references auth.users(id) on delete cascade,
  username          text unique not null
                      check (username ~ '^[a-zA-Z0-9_]{3,20}$'),
  display_name      text,
  avatar_url        text,
  faction_color     text not null default '#3B82F6'
                      check (faction_color ~* '^#[0-9a-f]{6}$'),

  -- denormalised counters, maintained by the claim RPC (cheap leaderboards)
  cells_owned       integer     not null default 0,
  total_steps       bigint      not null default 0,
  total_distance_m  bigint      not null default 0,
  total_effort      bigint      not null default 0,
  current_streak_d  integer     not null default 0,
  longest_streak_d  integer     not null default 0,
  last_active_date  date,

  -- anti-cheat
  suspicion_score   integer     not null default 0,
  is_shadow_banned  boolean     not null default false,

  home_region_h3    text,          -- res-5 cell, for local leaderboards
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create index profiles_region_idx     on public.profiles (home_region_h3, cells_owned desc);
create index profiles_leaderboard_idx on public.profiles (cells_owned desc)
  where is_shadow_banned = false;

alter table public.profiles enable row level security;

create policy "profiles are public"
  on public.profiles for select using (true);

-- Users may edit ONLY cosmetic fields. Counters are RPC-only.
create policy "users update own cosmetics"
  on public.profiles for update
  using  (auth.uid() = id)
  with check (auth.uid() = id);

-- Enforce which columns can actually change (RLS can't do column-level checks)
create or replace function public.guard_profile_update()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if current_setting('role', true) = 'authenticated' then
    new.cells_owned      := old.cells_owned;
    new.total_steps      := old.total_steps;
    new.total_distance_m := old.total_distance_m;
    new.total_effort     := old.total_effort;
    new.current_streak_d := old.current_streak_d;
    new.longest_streak_d := old.longest_streak_d;
    new.suspicion_score  := old.suspicion_score;
    new.is_shadow_banned := old.is_shadow_banned;
  end if;
  new.updated_at := now();
  return new;
end $$;

create trigger profiles_guard
  before update on public.profiles
  for each row execute function public.guard_profile_update();

-- Auto-create a profile on signup
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, username, display_name)
  values (
    new.id,
    coalesce(
      new.raw_user_meta_data->>'username',
      'walker_' || substr(replace(new.id::text,'-',''), 1, 8)
    ),
    new.raw_user_meta_data->>'full_name'
  );
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();


-- ---------------------------------------------------------------------------
-- 3. TERRITORIES  — one row per CLAIMED cell. Neutral cells are NOT stored.
--    (This is the key to fitting in 500 MB: absence == neutral.)
-- ---------------------------------------------------------------------------
create table public.territories (
  cell_id        text primary key,          -- H3 index, res 9, e.g. 8928308280fffff
  resolution     smallint    not null default 9,
  parent_res5    text        not null,      -- realtime channel + local leaderboard key

  owner_id       uuid        references public.profiles(id) on delete set null,
  owner_influence numeric(12,2) not null default 0,
  influence_at   timestamptz not null default now(),   -- decay reference point

  name           text        check (char_length(name) <= 32),
  color          text        check (color ~* '^#[0-9a-f]{6}$'),

  claimed_at     timestamptz not null default now(),
  last_claim_at  timestamptz not null default now(),
  claim_count    integer     not null default 1,       -- how many times it flipped

  -- centroid, only for map clustering / spatial queries. Optional.
  center         geography(Point, 4326)
);

create index territories_owner_idx  on public.territories (owner_id);
create index territories_parent_idx on public.territories (parent_res5);
create index territories_recent_idx on public.territories (last_claim_at desc);
-- GiST only if you actually do radius queries; it costs ~40 bytes/row.
-- create index territories_geo_idx on public.territories using gist (center);

alter table public.territories enable row level security;

create policy "territories are public"
  on public.territories for select using (true);

-- DELIBERATELY NO insert/update/delete policy for `authenticated`.
-- The ONLY writer is claim_cells(), which is SECURITY DEFINER.


-- ---------------------------------------------------------------------------
-- 4. USER × CELL INFLUENCE  — the contest accumulator
--    This is the biggest table. Keep it lean; prune decayed rows nightly.
-- ---------------------------------------------------------------------------
create table public.user_cell_influence (
  user_id      uuid        not null references public.profiles(id) on delete cascade,
  cell_id      text        not null,
  influence    numeric(12,2) not null default 0,
  influence_at timestamptz not null default now(),
  visits       integer     not null default 0,
  first_seen   timestamptz not null default now(),
  last_seen    timestamptz not null default now(),
  primary key (user_id, cell_id)
);

create index uci_cell_idx on public.user_cell_influence (cell_id, influence desc);
create index uci_prune_idx on public.user_cell_influence (influence_at)
  where influence < 400;

alter table public.user_cell_influence enable row level security;

create policy "users read own influence"
  on public.user_cell_influence for select
  using (auth.uid() = user_id);

-- Aggregate contest info is exposed via an RPC, never the raw table,
-- so you don't leak other players' movement patterns.


-- ---------------------------------------------------------------------------
-- 5. CLAIM EVENTS  — immutable ledger. Audit trail + anti-cheat forensics.
--    Partitioned by month so you can DROP old partitions instead of DELETE.
-- ---------------------------------------------------------------------------
create table public.claim_events (
  id           bigserial,
  user_id      uuid        not null,
  cell_id      text        not null,
  created_at   timestamptz not null default now(),

  steps        integer     not null,
  distance_m   integer     not null,
  dwell_s      integer     not null,
  fix_count    integer     not null,
  effort       numeric(10,2) not null,

  -- raw client claims, kept for forensics
  mean_accuracy_m numeric(6,2),
  max_speed_mps   numeric(6,2),
  window_start    timestamptz,
  window_end      timestamptz,

  outcome      text not null,   -- 'claimed' | 'reinforced' | 'contested' | 'rejected'
  reject_reason text,
  client_version text,
  primary key (id, created_at)
) partition by range (created_at);

-- Create partitions ahead of time (automate with pg_cron, see §8)
create table public.claim_events_2026_08 partition of public.claim_events
  for values from ('2026-08-01') to ('2026-09-01');
create table public.claim_events_2026_09 partition of public.claim_events
  for values from ('2026-09-01') to ('2026-10-01');
create table public.claim_events_2026_10 partition of public.claim_events
  for values from ('2026-10-01') to ('2026-11-01');

create index claim_events_user_idx on public.claim_events (user_id, created_at desc);

alter table public.claim_events enable row level security;
create policy "users read own events"
  on public.claim_events for select using (auth.uid() = user_id);


-- ---------------------------------------------------------------------------
-- 6. SYNC IDEMPOTENCY  — makes retries safe
-- ---------------------------------------------------------------------------
create table public.sync_receipts (
  user_id     uuid        not null references public.profiles(id) on delete cascade,
  batch_uuid  uuid        not null,
  received_at timestamptz not null default now(),
  result      jsonb,
  primary key (user_id, batch_uuid)
);

create index sync_receipts_ttl_idx on public.sync_receipts (received_at);

alter table public.sync_receipts enable row level security;
create policy "own receipts" on public.sync_receipts for select
  using (auth.uid() = user_id);


-- ---------------------------------------------------------------------------
-- 7. LAZY DECAY  — the function that makes decay free
-- ---------------------------------------------------------------------------
create or replace function public.current_influence(
  p_influence numeric,
  p_at        timestamptz
) returns numeric language sql immutable parallel safe as $$
  select round(
    p_influence * power(
      0.5,
      extract(epoch from (now() - p_at)) / (7 * 86400.0)   -- half-life 7 days
    )::numeric,
  2);
$$;
-- NB: half-life is hardcoded here so the function can be IMMUTABLE and used in
-- indexes/generated columns. If you tune it, bump a version suffix and migrate.


-- ---------------------------------------------------------------------------
-- 8. LEADERBOARDS  — materialised views, refreshed by cron (cheap reads)
-- ---------------------------------------------------------------------------
create materialized view public.leaderboard_global as
select
  p.id, p.username, p.display_name, p.avatar_url, p.faction_color,
  p.cells_owned, p.total_distance_m, p.total_effort,
  rank() over (order by p.cells_owned desc, p.total_effort desc) as rank
from public.profiles p
where p.is_shadow_banned = false and p.cells_owned > 0
order by rank
limit 500;

create unique index leaderboard_global_id_idx on public.leaderboard_global (id);

create materialized view public.leaderboard_local as
select
  t.parent_res5                         as region,
  t.owner_id                            as id,
  p.username, p.display_name, p.faction_color,
  count(*)                              as cells_in_region,
  rank() over (partition by t.parent_res5 order by count(*) desc) as rank
from public.territories t
join public.profiles p on p.id = t.owner_id
where p.is_shadow_banned = false
group by t.parent_res5, t.owner_id, p.username, p.display_name, p.faction_color;

create index leaderboard_local_region_idx on public.leaderboard_local (region, rank);
create unique index leaderboard_local_pk on public.leaderboard_local (region, id);

grant select on public.leaderboard_global, public.leaderboard_local to anon, authenticated;


-- ---------------------------------------------------------------------------
-- 9. MAINTENANCE JOBS
-- ---------------------------------------------------------------------------

-- 9a. Prune fully-decayed influence rows (reclaims the most disk)
create or replace function public.prune_decayed()
returns void language plpgsql security definer set search_path = public as $$
declare v_deleted int;
begin
  delete from public.user_cell_influence
  where public.current_influence(influence, influence_at) < 5;
  get diagnostics v_deleted = row_count;

  -- Cells whose owner has decayed below the neutral floor revert to neutral
  update public.territories t
     set owner_id = null, owner_influence = 0, name = null, color = null
   where t.owner_id is not null
     and public.current_influence(t.owner_influence, t.influence_at)
         < public.cfg('neutral_floor');

  delete from public.territories where owner_id is null;
  delete from public.sync_receipts where received_at < now() - interval '7 days';

  raise notice 'pruned % influence rows', v_deleted;
end $$;

-- 9b. Auto-create next month's claim_events partition
create or replace function public.ensure_next_partition()
returns void language plpgsql as $$
declare
  v_start date := date_trunc('month', now() + interval '1 month')::date;
  v_end   date := (date_trunc('month', now() + interval '2 month'))::date;
  v_name  text := 'claim_events_' || to_char(v_start, 'YYYY_MM');
begin
  if not exists (select 1 from pg_class where relname = v_name) then
    execute format(
      'create table public.%I partition of public.claim_events for values from (%L) to (%L)',
      v_name, v_start, v_end);
  end if;
end $$;

-- 9c. Schedule
select cron.schedule('prune-decayed',    '17 3 * * *',
  $$ select public.prune_decayed(); $$);
select cron.schedule('refresh-lb-global','*/10 * * * *',
  $$ refresh materialized view concurrently public.leaderboard_global; $$);
select cron.schedule('refresh-lb-local', '*/15 * * * *',
  $$ refresh materialized view concurrently public.leaderboard_local; $$);
select cron.schedule('ensure-partition', '0 0 25 * *',
  $$ select public.ensure_next_partition(); $$);
select cron.schedule('drop-old-events',  '30 3 1 * *',
  $$ do $x$ declare r record; begin
       for r in select relname from pg_class
                where relname like 'claim_events_20%'
                  and relname < 'claim_events_' ||
                      to_char(now() - interval '3 month','YYYY_MM')
       loop execute format('drop table public.%I', r.relname); end loop;
     end $x$; $$);

-- 9d. Keep the free project from being paused after 7 days of inactivity
--     (a trivial query counts as activity)
select cron.schedule('keepalive', '0 */6 * * *', $$ select 1; $$);


-- ---------------------------------------------------------------------------
-- 10. REALTIME
-- ---------------------------------------------------------------------------
-- We use BROADCAST from the RPC (not postgres_changes) because:
--   · postgres_changes sends the whole row to every subscriber of the table
--   · broadcast lets us scope to a res-5 region topic -> ~1000x fewer messages
-- No publication changes needed. See 02_CLAIM_ENGINE.sql for realtime.send().

-- If you DO want postgres_changes as a fallback, scope it tightly:
-- alter publication supabase_realtime add table public.territories;
