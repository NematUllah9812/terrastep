-- ============================================================================
-- TERRASTEP — Claim Engine
-- The server is the referee. This file contains the ONLY code path that is
-- allowed to write to `territories`.
-- ============================================================================
--
-- CLIENT CONTRACT
-- ---------------
-- The client calls:
--
--   supabase.rpc('claim_cells', {
--     p_batch_uuid: '<uuid v4, stable across retries>',
--     p_client_version: '1.0.3',
--     p_cells: [
--       { cell_id: '8928308280fffff', parent_res5: '8528308bfffffff',
--         lat: 34.1688, lng: 73.2215,
--         steps: 340, distance_m: 265, dwell_s: 410, fix_count: 78,
--         mean_accuracy_m: 8.2, max_speed_mps: 1.7,
--         window_start: '2026-08-17T09:00:00Z', window_end: '2026-08-17T09:07:00Z' },
--       ...
--     ]
--   })
--
-- Returns: jsonb array of per-cell outcomes.
-- Idempotent: replaying the same p_batch_uuid returns the cached result.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- Helper: haversine metres between two lat/lng pairs (no PostGIS needed)
-- ---------------------------------------------------------------------------
create or replace function public.haversine_m(
  lat1 double precision, lng1 double precision,
  lat2 double precision, lng2 double precision
) returns double precision language sql immutable parallel safe as $$
  select 6371000 * 2 * asin(sqrt(
      power(sin(radians(lat2 - lat1) / 2), 2) +
      cos(radians(lat1)) * cos(radians(lat2)) *
      power(sin(radians(lng2 - lng1) / 2), 2)
  ));
$$;


-- ---------------------------------------------------------------------------
-- Helper: effort score
-- ---------------------------------------------------------------------------
create or replace function public.compute_effort(
  p_steps int, p_distance_m int, p_dwell_s int
) returns numeric language sql stable parallel safe as $$
  select least(
    public.cfg('max_effort_per_visit'),
      p_steps      * public.cfg('effort_step_weight')
    + p_distance_m * public.cfg('effort_dist_weight')
    + p_dwell_s    * public.cfg('effort_dwell_weight')
  );
$$;


-- ---------------------------------------------------------------------------
-- Helper: validate one submitted cell. Returns null if OK, else reject reason.
-- This is the anti-cheat gate. Every rule here exists because of a specific
-- exploit — see 04_ANTI_CHEAT.md.
-- ---------------------------------------------------------------------------
create or replace function public.validate_cell_claim(c jsonb)
returns text language plpgsql stable as $$
declare
  v_steps    int  := coalesce((c->>'steps')::int, 0);
  v_dist     int  := coalesce((c->>'distance_m')::int, 0);
  v_dwell    int  := coalesce((c->>'dwell_s')::int, 0);
  v_fixes    int  := coalesce((c->>'fix_count')::int, 0);
  v_acc      numeric := coalesce((c->>'mean_accuracy_m')::numeric, 999);
  v_speed    numeric := coalesce((c->>'max_speed_mps')::numeric, 0);
  v_t0       timestamptz := (c->>'window_start')::timestamptz;
  v_t1       timestamptz := (c->>'window_end')::timestamptz;
  v_wall_s   numeric;
  v_ratio    numeric;
begin
  -- R1. Shape
  if c->>'cell_id' is null or length(c->>'cell_id') not between 15 and 16 then
    return 'bad_cell_id';
  end if;

  -- R2. Minimum-effort floors (the claim rule itself)
  if v_steps < public.cfg('claim_min_steps')      then return 'below_min_steps';    end if;
  if v_dist  < public.cfg('claim_min_distance_m') then return 'below_min_distance'; end if;
  if v_dwell < public.cfg('claim_min_dwell_s')    then return 'below_min_dwell';    end if;
  if v_fixes < public.cfg('claim_min_fixes')      then return 'too_few_fixes';      end if;

  -- R3. GPS quality
  if v_acc > public.cfg('max_accuracy_m') then return 'poor_gps_accuracy'; end if;

  -- R4. Speed envelope. 8 m/s ≈ 28.8 km/h. Above = vehicle, not a walk.
  if v_speed > public.cfg('max_speed_mps') then return 'implausible_speed'; end if;

  -- R5. Time coherence: claimed dwell cannot exceed the wall-clock window,
  --     and the window cannot be in the future or absurdly old.
  if v_t0 is null or v_t1 is null then return 'missing_window'; end if;
  v_wall_s := extract(epoch from (v_t1 - v_t0));
  if v_wall_s <= 0                     then return 'inverted_window';  end if;
  if v_dwell > v_wall_s * 1.05         then return 'dwell_exceeds_window'; end if;
  if v_t1 > now() + interval '5 minutes' then return 'future_window'; end if;
  if v_t0 < now() - interval '48 hours'  then return 'stale_window';  end if;

  -- R6. Step/distance ratio. A human stride is 0.4–1.2 m.
  --     Shaking the phone -> many steps, no distance -> ratio collapses.
  --     Driving/spoofing  -> much distance, few steps -> ratio explodes.
  v_ratio := v_dist::numeric / greatest(v_steps, 1);
  if v_ratio < 0.30 then return 'steps_without_distance'; end if;  -- shaking
  if v_ratio > 1.60 then return 'distance_without_steps'; end if;  -- vehicle/spoof

  -- R7. Implied average speed over the dwell window
  if v_dist::numeric / greatest(v_dwell, 1) > public.cfg('max_speed_mps') then
    return 'implausible_avg_speed';
  end if;

  -- R8. Cadence sanity: >3.5 steps/second is not human
  if v_steps::numeric / greatest(v_dwell, 1) > 3.5 then return 'implausible_cadence'; end if;

  return null;   -- valid
end $$;


-- ============================================================================
-- THE MAIN RPC
-- ============================================================================
create or replace function public.claim_cells(
  p_batch_uuid     uuid,
  p_cells          jsonb,
  p_client_version text default 'unknown'
) returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user        uuid := auth.uid();
  v_banned      boolean;
  v_cached      jsonb;
  v_cell        jsonb;
  v_results     jsonb := '[]'::jsonb;

  v_cell_id     text;
  v_parent5     text;
  v_reject      text;
  v_effort      numeric;

  v_prev_cell_id text;
  v_prev_lat    double precision;
  v_prev_lng    double precision;
  v_prev_t1     timestamptz;
  v_gap_m       double precision;
  v_gap_s       numeric;

  v_my_inf      numeric;
  v_top_other   record;
  v_owner       uuid;
  v_owner_inf   numeric;
  v_outcome     text;

  v_hour_count  int;
  v_day_count   int;
  v_steps_total bigint := 0;
  v_dist_total  bigint := 0;
  v_effort_total numeric := 0;
  v_newly_owned int := 0;
  v_changed     jsonb := '[]'::jsonb;
begin
  ------------------------------------------------------------------ auth
  if v_user is null then
    raise exception 'unauthenticated' using errcode = '28000';
  end if;

  select is_shadow_banned into v_banned from public.profiles where id = v_user;
  if v_banned then
    -- Shadow ban: pretend everything worked, write nothing.
    return jsonb_build_object('ok', true, 'shadow', true, 'results', '[]'::jsonb);
  end if;

  ------------------------------------------------- idempotency (retry safe)
  select result into v_cached
    from public.sync_receipts
   where user_id = v_user and batch_uuid = p_batch_uuid;
  if found then
    return v_cached;
  end if;

  ------------------------------------------------------------ rate limits
  select count(*) into v_hour_count
    from public.claim_events
   where user_id = v_user
     and created_at > now() - interval '1 hour'
     and outcome <> 'rejected';

  select count(*) into v_day_count
    from public.claim_events
   where user_id = v_user
     and created_at > now() - interval '24 hours'
     and outcome <> 'rejected';

  if v_hour_count >= cfg('max_cells_per_hour')
     or v_day_count >= cfg('max_cells_per_day') then
    update public.profiles
       set suspicion_score = suspicion_score + 5
     where id = v_user;
    return jsonb_build_object('ok', false, 'error', 'rate_limited',
                              'retry_after_s', 3600);
  end if;

  ------------------------------------------------------- per-cell processing
  -- Sort by window_start so path-continuity checks are meaningful.
  for v_cell in
    select value from jsonb_array_elements(p_cells) as t(value)
    order by (value->>'window_start')::timestamptz
  loop
    v_cell_id := v_cell->>'cell_id';
    v_parent5 := v_cell->>'parent_res5';
    v_outcome := null;

    -- ---- validation gate
    v_reject := public.validate_cell_claim(v_cell);

    -- ---- R9. Path continuity: you cannot teleport between cells.
    -- Distance between consecutive cell centroids vs. elapsed time.
    if v_reject is null and v_prev_lat is not null then
      v_gap_m := public.haversine_m(
                   v_prev_lat, v_prev_lng,
                   (v_cell->>'lat')::double precision,
                   (v_cell->>'lng')::double precision);
      v_gap_s := greatest(
                   extract(epoch from ((v_cell->>'window_start')::timestamptz - v_prev_t1)),
                   1);
      -- allow a generous 15 m/s for the gap (covers a bus ride between walks)
      -- but not 500 km in 10 seconds
      if v_gap_m / v_gap_s > 15.0 and v_gap_m > 300 then
        v_reject := 'teleport_between_cells';
      end if;
    end if;

    -- [H3-PG] Stronger check if the h3 extension is installed — uncomment:
    -- if v_reject is null and v_prev_cell_id is not null then
    --   if h3_grid_distance(v_prev_cell_id::h3index, v_cell_id::h3index) > 3
    --      and v_gap_s < 120 then
    --     v_reject := 'non_contiguous_path';
    --   end if;
    -- end if;
    --
    -- [H3-PG] Verify the client's cell_id actually matches its lat/lng:
    -- if v_reject is null and
    --    h3_lat_lng_to_cell(point((v_cell->>'lng')::float8,(v_cell->>'lat')::float8),
    --                       cfg('h3_resolution')::int)::text <> v_cell_id then
    --   v_reject := 'cell_coordinate_mismatch';
    -- end if;

    ---------------------------------------------------------- rejected path
    if v_reject is not null then
      insert into public.claim_events (
        user_id, cell_id, steps, distance_m, dwell_s, fix_count, effort,
        mean_accuracy_m, max_speed_mps, window_start, window_end,
        outcome, reject_reason, client_version)
      values (
        v_user, coalesce(v_cell_id,'?'),
        coalesce((v_cell->>'steps')::int,0), coalesce((v_cell->>'distance_m')::int,0),
        coalesce((v_cell->>'dwell_s')::int,0), coalesce((v_cell->>'fix_count')::int,0),
        0,
        (v_cell->>'mean_accuracy_m')::numeric, (v_cell->>'max_speed_mps')::numeric,
        (v_cell->>'window_start')::timestamptz, (v_cell->>'window_end')::timestamptz,
        'rejected', v_reject, p_client_version);

      -- Hard-cheat signals bump suspicion; soft ones (below threshold) don't.
      if v_reject in ('teleport_between_cells','steps_without_distance',
                      'distance_without_steps','implausible_cadence',
                      'dwell_exceeds_window','future_window',
                      'cell_coordinate_mismatch','non_contiguous_path') then
        update public.profiles set suspicion_score = suspicion_score + 2
         where id = v_user;
      end if;

      v_results := v_results || jsonb_build_object(
        'cell_id', v_cell_id, 'outcome', 'rejected', 'reason', v_reject);

      -- still advance the path cursor so we don't cascade false teleports
      v_prev_cell_id := v_cell_id;
      v_prev_lat := (v_cell->>'lat')::double precision;
      v_prev_lng := (v_cell->>'lng')::double precision;
      v_prev_t1  := (v_cell->>'window_end')::timestamptz;
      continue;
    end if;

    ----------------------------------------------------------- accepted path
    v_effort := public.compute_effort(
      (v_cell->>'steps')::int, (v_cell->>'distance_m')::int, (v_cell->>'dwell_s')::int);

    -- 1) upsert MY influence, applying lazy decay to the old value first
    insert into public.user_cell_influence
      (user_id, cell_id, influence, influence_at, visits, last_seen)
    values (v_user, v_cell_id, v_effort, now(), 1, now())
    on conflict (user_id, cell_id) do update
      set influence = public.current_influence(
                        user_cell_influence.influence,
                        user_cell_influence.influence_at) + excluded.influence,
          influence_at = now(),
          visits    = user_cell_influence.visits + 1,
          last_seen = now()
    returning influence into v_my_inf;

    -- 2) who currently owns it, and at what decayed strength?
    select owner_id,
           public.current_influence(owner_influence, influence_at)
      into v_owner, v_owner_inf
      from public.territories
     where cell_id = v_cell_id
     for update;                        -- row lock: serialises concurrent claims

    -- 3) decide the outcome
    if v_owner is null then
      -- unowned (or row doesn't exist) -> claim it
      insert into public.territories
        (cell_id, resolution, parent_res5, owner_id, owner_influence, influence_at,
         claimed_at, last_claim_at, claim_count, center)
      values
        (v_cell_id, cfg('h3_resolution')::smallint, v_parent5, v_user, v_my_inf, now(),
         now(), now(), 1,
         null)  -- centroid optional; st_point needs PostGIS on search_path
      on conflict (cell_id) do update
        set owner_id = v_user, owner_influence = v_my_inf, influence_at = now(),
            last_claim_at = now(), claim_count = territories.claim_count + 1;
      v_outcome := 'claimed';
      v_newly_owned := v_newly_owned + 1;

    elsif v_owner = v_user then
      -- reinforce my own tile
      update public.territories
         set owner_influence = v_my_inf, influence_at = now(),
             last_claim_at = now()
       where cell_id = v_cell_id;
      v_outcome := 'reinforced';

    else
      -- contested. Hysteresis prevents flip-flop spam.
      if v_my_inf > v_owner_inf * cfg('takeover_multiplier') + cfg('takeover_flat_margin')
      then
        update public.territories
           set owner_id = v_user, owner_influence = v_my_inf, influence_at = now(),
               last_claim_at = now(), claim_count = claim_count + 1,
               name = null, color = null       -- new owner, fresh identity
         where cell_id = v_cell_id;

        -- decrement the loser's counter
        update public.profiles set cells_owned = greatest(cells_owned - 1, 0)
         where id = v_owner;

        v_outcome := 'captured';
        v_newly_owned := v_newly_owned + 1;
      else
        v_outcome := 'contested';   -- progress made, not enough to flip
      end if;
    end if;

    -- 4) ledger
    insert into public.claim_events (
      user_id, cell_id, steps, distance_m, dwell_s, fix_count, effort,
      mean_accuracy_m, max_speed_mps, window_start, window_end,
      outcome, client_version)
    values (
      v_user, v_cell_id,
      (v_cell->>'steps')::int, (v_cell->>'distance_m')::int,
      (v_cell->>'dwell_s')::int, (v_cell->>'fix_count')::int, v_effort,
      (v_cell->>'mean_accuracy_m')::numeric, (v_cell->>'max_speed_mps')::numeric,
      (v_cell->>'window_start')::timestamptz, (v_cell->>'window_end')::timestamptz,
      v_outcome, p_client_version);

    -- 5) accumulate for the profile update
    v_steps_total  := v_steps_total  + (v_cell->>'steps')::int;
    v_dist_total   := v_dist_total   + (v_cell->>'distance_m')::int;
    v_effort_total := v_effort_total + v_effort;

    v_results := v_results || jsonb_build_object(
      'cell_id', v_cell_id, 'outcome', v_outcome,
      'my_influence', v_my_inf, 'effort', v_effort);

    if v_outcome in ('claimed','captured') then
      v_changed := v_changed || jsonb_build_object(
        'cell_id', v_cell_id, 'parent_res5', v_parent5,
        'owner_id', v_user, 'outcome', v_outcome);
    end if;

    v_prev_cell_id := v_cell_id;
    v_prev_lat := (v_cell->>'lat')::double precision;
    v_prev_lng := (v_cell->>'lng')::double precision;
    v_prev_t1  := (v_cell->>'window_end')::timestamptz;
  end loop;

  --------------------------------------------------------- profile rollup
  update public.profiles p
     set total_steps      = p.total_steps + v_steps_total,
         total_distance_m = p.total_distance_m + v_dist_total,
         total_effort     = p.total_effort + v_effort_total::bigint,
         cells_owned      = (select count(*) from public.territories
                              where owner_id = v_user),
         current_streak_d = case
              when p.last_active_date = current_date then p.current_streak_d
              when p.last_active_date = current_date - 1 then p.current_streak_d + 1
              else 1 end,
         longest_streak_d = greatest(p.longest_streak_d,
              case
                when p.last_active_date = current_date then p.current_streak_d
                when p.last_active_date = current_date - 1 then p.current_streak_d + 1
                else 1 end),
         last_active_date = current_date,
         home_region_h3   = coalesce(p.home_region_h3,
                                     (p_cells->0->>'parent_res5')),
         updated_at       = now()
   where p.id = v_user;

  ------------------------------------------------------------- realtime
  -- Phase 3. Must never abort a successful claim if realtime is missing (O2).
  begin
    perform realtime.send(
        jsonb_build_object('type','cells_changed','cells', region_cells),
        'cells_changed',
        'region:' || region_key,
        false
      )
    from (
      select c->>'parent_res5' as region_key,
             jsonb_agg(c)      as region_cells
        from jsonb_array_elements(v_changed) as c
       group by 1
    ) grouped;
  exception when others then
    raise notice 'realtime.send skipped: %', sqlerrm;
  end;

  -------------------------------------------------------------- receipt
  v_cached := jsonb_build_object(
    'ok', true,
    'results', v_results,
    'newly_owned', v_newly_owned,
    'server_time', now());

  insert into public.sync_receipts (user_id, batch_uuid, result)
  values (v_user, p_batch_uuid, v_cached)
  on conflict do nothing;

  return v_cached;
end $$;

revoke all on function public.claim_cells(uuid, jsonb, text) from public, anon;
grant execute on function public.claim_cells(uuid, jsonb, text) to authenticated;


-- ============================================================================
-- READ RPC — fetch ownership for the current viewport
-- ============================================================================
-- The client computes which H3 cells are visible (h3.polygonToCells of the map
-- bounds) and asks only for those. Cap the array size to protect egress.
create or replace function public.get_cells_in_view(p_cells text[])
returns table (
  cell_id text, owner_id uuid, username text, color text,
  name text, influence numeric, is_mine boolean
)
language sql stable security definer set search_path = public as $$
  select t.cell_id,
         t.owner_id,
         p.username,
         coalesce(t.color, p.faction_color) as color,
         t.name,
         public.current_influence(t.owner_influence, t.influence_at) as influence,
         (t.owner_id = auth.uid()) as is_mine
    from public.territories t
    join public.profiles p on p.id = t.owner_id
   where t.cell_id = any(p_cells[1:2000])   -- hard cap
     and p.is_shadow_banned = false;
$$;

grant execute on function public.get_cells_in_view(text[]) to anon, authenticated;


-- Region-scoped variant: cheaper for a zoomed-out map.
create or replace function public.get_cells_in_region(p_region_res5 text)
returns table (cell_id text, owner_id uuid, color text, name text)
language sql stable security definer set search_path = public as $$
  select t.cell_id, t.owner_id,
         coalesce(t.color, p.faction_color), t.name
    from public.territories t
    join public.profiles p on p.id = t.owner_id
   where t.parent_res5 = p_region_res5
     and p.is_shadow_banned = false
   limit 5000;
$$;

grant execute on function public.get_cells_in_region(text) to anon, authenticated;


-- ============================================================================
-- TERRITORY CUSTOMISATION
-- ============================================================================
create or replace function public.update_territory(
  p_cell_id text, p_name text, p_color text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_owner uuid;
begin
  select owner_id into v_owner from public.territories where cell_id = p_cell_id;
  if v_owner is null or v_owner <> auth.uid() then
    return jsonb_build_object('ok', false, 'error', 'not_owner');
  end if;

  if p_name is not null and char_length(p_name) > 32 then
    return jsonb_build_object('ok', false, 'error', 'name_too_long');
  end if;
  if p_color is not null and p_color !~* '^#[0-9a-f]{6}$' then
    return jsonb_build_object('ok', false, 'error', 'bad_color');
  end if;
  -- TODO: profanity filter on p_name before launch.

  update public.territories
     set name = p_name, color = p_color
   where cell_id = p_cell_id;

  return jsonb_build_object('ok', true);
end $$;

grant execute on function public.update_territory(text, text, text) to authenticated;


-- ============================================================================
-- CONTEST INFO — what the tile-detail sheet shows (no raw tracks leaked)
-- ============================================================================
create or replace function public.get_cell_detail(p_cell_id text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'cell_id', p_cell_id,
    'owner', (select jsonb_build_object('username', p.username,
                                        'color', coalesce(t.color, p.faction_color),
                                        'name', t.name,
                                        'claimed_at', t.claimed_at,
                                        'influence', public.current_influence(
                                            t.owner_influence, t.influence_at))
                from public.territories t
                join public.profiles p on p.id = t.owner_id
               where t.cell_id = p_cell_id),
    'my_influence', (select public.current_influence(influence, influence_at)
                       from public.user_cell_influence
                      where cell_id = p_cell_id and user_id = auth.uid()),
    'contenders', (select count(*) from public.user_cell_influence
                    where cell_id = p_cell_id
                      and public.current_influence(influence, influence_at) > 20),
    'effort_to_capture', (
      select greatest(0,
        public.current_influence(t.owner_influence, t.influence_at)
          * public.cfg('takeover_multiplier') + public.cfg('takeover_flat_margin')
        - coalesce((select public.current_influence(influence, influence_at)
                      from public.user_cell_influence
                     where cell_id = p_cell_id and user_id = auth.uid()), 0))
        from public.territories t where t.cell_id = p_cell_id)
  );
$$;

grant execute on function public.get_cell_detail(text) to authenticated;


-- ============================================================================
-- ADMIN: revert everything a cheater ever did
-- ============================================================================
create or replace function public.admin_rollback_user(p_user uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_cells int;
begin
  -- Guard: only callable with the service_role key
  if current_setting('request.jwt.claims', true)::jsonb->>'role' <> 'service_role' then
    raise exception 'forbidden';
  end if;

  delete from public.user_cell_influence where user_id = p_user;

  -- Reassign or neutralise their tiles: next-strongest contender takes over
  with reassigned as (
    select t.cell_id,
           (select u.user_id from public.user_cell_influence u
             where u.cell_id = t.cell_id
               and public.current_influence(u.influence, u.influence_at)
                   >= public.cfg('neutral_floor')
             order by public.current_influence(u.influence, u.influence_at) desc
             limit 1) as new_owner
      from public.territories t
     where t.owner_id = p_user
  )
  update public.territories t
     set owner_id = r.new_owner,
         owner_influence = coalesce(
            (select public.current_influence(u.influence, u.influence_at)
               from public.user_cell_influence u
              where u.cell_id = t.cell_id and u.user_id = r.new_owner), 0),
         influence_at = now(), name = null, color = null
    from reassigned r
   where t.cell_id = r.cell_id;
  get diagnostics v_cells = row_count;

  delete from public.territories where owner_id is null;

  update public.profiles
     set is_shadow_banned = true, cells_owned = 0,
         total_steps = 0, total_distance_m = 0, total_effort = 0
   where id = p_user;

  return jsonb_build_object('ok', true, 'cells_reverted', v_cells);
end $$;


-- Match the client GPS gate (Abbottabad fused lock is often >35 m).
update public.game_config
   set value = 80, description = 'GPS fixes worse than this are dropped (aligned with client)'
 where key = 'max_accuracy_m';
