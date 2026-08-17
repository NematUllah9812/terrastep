-- ===========================================================================
-- TERRASTEP — Engine acceptance tests
-- Run after 00_shim.sql + 01_DATA_MODEL.sql + 02_CLAIM_ENGINE.sql
-- Every one of these MUST pass before Phase 2 threshold 2.5 is signed off.
-- ===========================================================================
\set ON_ERROR_STOP on
\timing off

create or replace function tests.check(label text, got text, want text)
returns void language plpgsql as $$
begin
  if got is not distinct from want then
    raise notice 'PASS  %  (%)', rpad(label, 42), got;
  else
    raise warning 'FAIL  %  got=%  want=%', rpad(label, 42), got, want;
    update tests.state set failures = failures + 1;
  end if;
end $$;

-- ---------------------------------------------------------------- fixtures
truncate public.claim_events, public.user_cell_influence,
         public.territories, public.sync_receipts restart identity cascade;
delete from public.profiles;
delete from auth.users;

insert into auth.users (id, email, raw_user_meta_data) values
  ('11111111-1111-1111-1111-111111111111','a@t.io','{"username":"alice"}'),
  ('22222222-2222-2222-2222-222222222222','b@t.io','{"username":"bob"}');

-- helper: build a cell payload
create or replace function tests.cell(
  p_cell text, p_lat float8, p_lng float8,
  p_steps int, p_dist int, p_dwell int, p_fixes int default 40,
  p_acc numeric default 8.5, p_speed numeric default 1.4,
  p_t0 timestamptz default now() - interval '10 min',
  p_t1 timestamptz default now() - interval '1 min'
) returns jsonb language sql as $$
  select jsonb_build_object(
    'cell_id', p_cell, 'parent_res5','8528308bfffffff',
    'lat', p_lat, 'lng', p_lng,
    'steps', p_steps, 'distance_m', p_dist, 'dwell_s', p_dwell,
    'fix_count', p_fixes, 'mean_accuracy_m', p_acc, 'max_speed_mps', p_speed,
    'window_start', p_t0, 'window_end', p_t1);
$$;

-- Abbottabad-ish coordinates
-- C1 and C2 are ~400m apart (adjacent cells); C_FAR is Karachi.
\set C1  '''8928308280fffff'''
\set C2  '''8928308281fffff'''
\set CF  '''89283082abfffff'''

do $$ begin perform set_config('test.uid','11111111-1111-1111-1111-111111111111',false); end $$;

-- ===========================================================================
-- GROUP A — validate_cell_claim() rejection rules
-- ===========================================================================
\echo ''
\echo '--- A. VALIDATION RULES -------------------------------------------'
select tests.check('A1 valid walk accepted',
  coalesce(public.validate_cell_claim(
    tests.cell('8928308280fffff',34.1688,73.2215, 400,310,420)),'ok'), 'ok');

-- Crude shake: trips the distance floor first.
select tests.check('A2a crude shake (2000 steps, 5m)',
  public.validate_cell_claim(
    tests.cell('8928308280fffff',34.1688,73.2215, 2000,5,600,50,8,0.2)),
  'below_min_distance');

-- Sophisticated shake: walks 90m to clear the floor, then shakes for steps.
-- ratio = 90/2000 = 0.045 -> caught by R6, which is the point of R6.
select tests.check('A2b smart shake (2000 steps, 90m)',
  public.validate_cell_claim(
    tests.cell('8928308280fffff',34.1688,73.2215, 2000,90,500,50,8,0.9)),
  'steps_without_distance');

select tests.check('A3 driving (speed 20 m/s)',
  public.validate_cell_claim(
    tests.cell('8928308280fffff',34.1688,73.2215, 400,310,420,40,8,20.0)),
  'implausible_speed');

select tests.check('A4 vehicle ratio (150 steps, 900m)',
  public.validate_cell_claim(
    tests.cell('8928308280fffff',34.1688,73.2215, 150,900,420,40,8,3.0)),
  'distance_without_steps');

select tests.check('A5 below min steps',
  public.validate_cell_claim(
    tests.cell('8928308280fffff',34.1688,73.2215, 50,310,420)),
  'below_min_steps');

select tests.check('A6 below min dwell',
  public.validate_cell_claim(
    tests.cell('8928308280fffff',34.1688,73.2215, 400,310,30)),
  'below_min_dwell');

select tests.check('A7 poor GPS accuracy',
  public.validate_cell_claim(
    tests.cell('8928308280fffff',34.1688,73.2215, 400,310,420,40,120.0)),
  'poor_gps_accuracy');

select tests.check('A8 stale window (3 days old)',
  public.validate_cell_claim(
    tests.cell('8928308280fffff',34.1688,73.2215, 400,310,420,40,8,1.4,
      now()-interval '3 days', now()-interval '3 days'+interval '9 min')),
  'stale_window');

select tests.check('A9 dwell exceeds wall clock',
  public.validate_cell_claim(
    tests.cell('8928308280fffff',34.1688,73.2215, 400,310,7200,40,8,1.4,
      now()-interval '10 min', now()-interval '1 min')),
  'dwell_exceeds_window');

select tests.check('A10 future window',
  public.validate_cell_claim(
    tests.cell('8928308280fffff',34.1688,73.2215, 400,310,420,40,8,1.4,
      now()+interval '1 hour', now()+interval '2 hour')),
  'future_window');

select tests.check('A11 impossible cadence',
  public.validate_cell_claim(
    tests.cell('8928308280fffff',34.1688,73.2215, 1000,700,120,40,8,1.4)),
  'implausible_cadence');

select tests.check('A12 too few GPS fixes',
  public.validate_cell_claim(
    tests.cell('8928308280fffff',34.1688,73.2215, 400,310,420,2)),
  'too_few_fixes');

-- ===========================================================================
-- GROUP B — effort maths
-- ===========================================================================
\echo ''
\echo '--- B. EFFORT SCORING ---------------------------------------------'
-- 400*1.0 + 310*0.35 + 420*0.05 = 400 + 108.5 + 21 = 529.5
select tests.check('B1 effort formula',
  public.compute_effort(400,310,420)::text, '529.50');

-- cap at 600
select tests.check('B2 effort capped at 600',
  public.compute_effort(5000,5000,5000)::text, '600');

-- ===========================================================================
-- GROUP C — claim / reinforce / contest / capture
-- ===========================================================================
\echo ''
\echo '--- C. OWNERSHIP LIFECYCLE ----------------------------------------'

-- C1: Alice claims a neutral cell
select tests.check('C1 alice claims neutral cell',
  (public.claim_cells(gen_random_uuid(),
     jsonb_build_array(tests.cell('8928308280fffff',34.1688,73.2215,400,310,420))
   )->'results'->0->>'outcome'), 'claimed');

select tests.check('C2 territory row owned by alice',
  (select owner_id::text from public.territories where cell_id='8928308280fffff'),
  '11111111-1111-1111-1111-111111111111');

select tests.check('C3 alice influence = 529.50',
  (select influence::text from public.user_cell_influence
    where user_id='11111111-1111-1111-1111-111111111111'
      and cell_id='8928308280fffff'), '529.50');

-- C4: Alice walks it again -> reinforced, influence accumulates
select tests.check('C4 alice reinforces own cell',
  (public.claim_cells(gen_random_uuid(),
     jsonb_build_array(tests.cell('8928308280fffff',34.1688,73.2215,400,310,420))
   )->'results'->0->>'outcome'), 'reinforced');

-- ~1059 (529.5 + 529.5, minus a hair of decay)
select tests.check('C5 influence accumulated > 1050',
  (select (influence > 1050)::text from public.user_cell_influence
    where user_id='11111111-1111-1111-1111-111111111111'
      and cell_id='8928308280fffff'), 'true');

-- C6: Bob attacks with LESS than the hysteresis bar -> contested, no flip
do $$ begin perform set_config('test.uid','22222222-2222-2222-2222-222222222222',false); end $$;

select tests.check('C6 bob attack #1 -> contested (not enough)',
  (public.claim_cells(gen_random_uuid(),
     jsonb_build_array(tests.cell('8928308280fffff',34.1688,73.2215,400,310,420))
   )->'results'->0->>'outcome'), 'contested');

select tests.check('C7 alice still owns it',
  (select owner_id::text from public.territories where cell_id='8928308280fffff'),
  '11111111-1111-1111-1111-111111111111');

-- C8: Bob keeps walking. Bar = 1059*1.15+50 = ~1268. Bob needs 3 visits.
select public.claim_cells(gen_random_uuid(),
  jsonb_build_array(tests.cell('8928308280fffff',34.1688,73.2215,400,310,420)));
select public.claim_cells(gen_random_uuid(),
  jsonb_build_array(tests.cell('8928308280fffff',34.1688,73.2215,400,310,420)));

select tests.check('C8 bob eventually captures',
  (select owner_id::text from public.territories where cell_id='8928308280fffff'),
  '22222222-2222-2222-2222-222222222222');

select tests.check('C9 claim_count incremented',
  (select (claim_count >= 2)::text from public.territories
    where cell_id='8928308280fffff'), 'true');

select tests.check('C10 alice cells_owned decremented to 0',
  (select cells_owned::text from public.profiles
    where id='11111111-1111-1111-1111-111111111111'), '0');

-- ===========================================================================
-- GROUP D — hysteresis boundary (the exact flip point)
-- ===========================================================================
\echo ''
\echo '--- D. HYSTERESIS ---------------------------------------------------'
truncate public.territories, public.user_cell_influence cascade;

-- Plant a defender with influence exactly 300
insert into public.territories (cell_id, parent_res5, owner_id, owner_influence, influence_at)
values ('8928308299fffff','8528308bfffffff','11111111-1111-1111-1111-111111111111',300,now());
insert into public.user_cell_influence (user_id, cell_id, influence, influence_at)
values ('11111111-1111-1111-1111-111111111111','8928308299fffff',300,now());

-- bar = 300*1.15 + 50 = 395
select tests.check('D1 takeover bar is 395',
  (300 * public.cfg('takeover_multiplier') + public.cfg('takeover_flat_margin'))::text,
  '395.00');

-- Bob arrives with effort 385.5 (350 steps,100m,10s->but must pass floors)
-- use 300 steps, 250m, 300s = 300 + 87.5 + 15 = 402.5  -> should CAPTURE (402.5>395)
do $$ begin perform set_config('test.uid','22222222-2222-2222-2222-222222222222',false); end $$;
select tests.check('D2 effort 402.5 > bar 395 -> captured',
  (public.claim_cells(gen_random_uuid(),
     jsonb_build_array(tests.cell('8928308299fffff',34.17,73.22,300,250,300))
   )->'results'->0->>'outcome'), 'captured');

-- Reset and try just UNDER the bar: 250 steps,200m,250s = 250+70+12.5 = 332.5 < 395
truncate public.territories, public.user_cell_influence cascade;
insert into public.territories (cell_id, parent_res5, owner_id, owner_influence, influence_at)
values ('8928308299fffff','8528308bfffffff','11111111-1111-1111-1111-111111111111',300,now());

select tests.check('D3 effort 332.5 < bar 395 -> contested',
  (public.claim_cells(gen_random_uuid(),
     jsonb_build_array(tests.cell('8928308299fffff',34.17,73.22,250,200,250))
   )->'results'->0->>'outcome'), 'contested');

-- ===========================================================================
-- GROUP E — lazy decay
-- ===========================================================================
\echo ''
\echo '--- E. DECAY --------------------------------------------------------'
select tests.check('E1 no decay at t=0',
  public.current_influence(1000, now())::text, '1000.00');

select tests.check('E2 half-life 7d -> 500',
  public.current_influence(1000, now() - interval '7 days')::text, '500.00');

select tests.check('E3 two half-lives -> 250',
  public.current_influence(1000, now() - interval '14 days')::text, '250.00');

select tests.check('E4 28 days -> 62.5 (below neutral floor 100)',
  (public.current_influence(1000, now() - interval '28 days')
     < public.cfg('neutral_floor'))::text, 'true');

-- prune reverts decayed cells to neutral
truncate public.territories, public.user_cell_influence cascade;
insert into public.territories (cell_id, parent_res5, owner_id, owner_influence, influence_at)
values ('892830aaafffff1','8528308bfffffff','11111111-1111-1111-1111-111111111111',
        1000, now() - interval '40 days');

select public.prune_decayed();

select tests.check('E5 fully-decayed cell removed by prune',
  (select count(*)::text from public.territories where cell_id='892830aaafffff1'), '0');

-- a fresh cell survives the prune
insert into public.territories (cell_id, parent_res5, owner_id, owner_influence, influence_at)
values ('892830aaafffff2','8528308bfffffff','11111111-1111-1111-1111-111111111111',
        1000, now());
select public.prune_decayed();
select tests.check('E6 fresh cell survives prune',
  (select count(*)::text from public.territories where cell_id='892830aaafffff2'), '1');

-- ===========================================================================
-- GROUP F — idempotency & anti-replay
-- ===========================================================================
\echo ''
\echo '--- F. IDEMPOTENCY --------------------------------------------------'
truncate public.territories, public.user_cell_influence,
         public.claim_events, public.sync_receipts cascade;
do $$ begin perform set_config('test.uid','11111111-1111-1111-1111-111111111111',false); end $$;

do $$
declare v_batch uuid := gen_random_uuid(); v_r1 jsonb; v_r2 jsonb;
begin
  v_r1 := public.claim_cells(v_batch,
    jsonb_build_array(tests.cell('892830bbbfffff1',34.18,73.23,400,310,420)));
  v_r2 := public.claim_cells(v_batch,   -- exact same batch id = network retry
    jsonb_build_array(tests.cell('892830bbbfffff1',34.18,73.23,400,310,420)));
  perform tests.check('F1 retry returns cached result',
    (v_r1 = v_r2)::text, 'true');
end $$;

select tests.check('F2 retry did NOT double-count influence',
  (select influence::text from public.user_cell_influence
    where cell_id='892830bbbfffff1'), '529.50');

select tests.check('F3 only one claim_event written',
  (select count(*)::text from public.claim_events
    where cell_id='892830bbbfffff1'), '1');

-- ===========================================================================
-- GROUP G — teleport / path continuity
-- ===========================================================================
\echo ''
\echo '--- G. PATH CONTINUITY ----------------------------------------------'
truncate public.territories, public.user_cell_influence, public.claim_events cascade;

-- Abbottabad (34.17, 73.22) then Karachi (24.86, 67.00) 60 seconds later
do $$
declare v_res jsonb;
begin
  v_res := public.claim_cells(gen_random_uuid(), jsonb_build_array(
    tests.cell('892830ccc000001',34.1688,73.2215,400,310,420,40,8,1.4,
      now()-interval '20 min', now()-interval '13 min'),
    tests.cell('892830ccc000002',24.8607,67.0011,400,310,420,40,8,1.4,
      now()-interval '12 min', now()-interval '5 min')
  ));
  perform tests.check('G1 first cell accepted',
    v_res->'results'->0->>'outcome', 'claimed');
  perform tests.check('G2 teleport to Karachi rejected',
    v_res->'results'->1->>'reason', 'teleport_between_cells');
end $$;

select tests.check('G3 suspicion score bumped for teleport',
  (select (suspicion_score >= 2)::text from public.profiles
    where id='11111111-1111-1111-1111-111111111111'), 'true');

-- adjacent cells 400m apart, 1 min apart -> fine (0.4km/60s = 6.7 m/s, under 15)
truncate public.territories, public.user_cell_influence, public.claim_events cascade;
do $$
declare v_res jsonb;
begin
  v_res := public.claim_cells(gen_random_uuid(), jsonb_build_array(
    tests.cell('892830ddd000001',34.1688,73.2215,400,310,420,40,8,1.4,
      now()-interval '20 min', now()-interval '13 min'),
    tests.cell('892830ddd000002',34.1724,73.2215,400,310,420,40,8,1.4,
      now()-interval '12 min', now()-interval '5 min')
  ));
  perform tests.check('G4 adjacent cell walk accepted',
    v_res->'results'->1->>'outcome', 'claimed');
end $$;

-- ===========================================================================
-- GROUP H — shadow ban & rate limit
-- ===========================================================================
\echo ''
\echo '--- H. ENFORCEMENT --------------------------------------------------'
update public.profiles set is_shadow_banned = true
 where id='22222222-2222-2222-2222-222222222222';
do $$ begin perform set_config('test.uid','22222222-2222-2222-2222-222222222222',false); end $$;

do $$
declare v_res jsonb;
begin
  v_res := public.claim_cells(gen_random_uuid(),
    jsonb_build_array(tests.cell('892830eee000001',34.18,73.23,400,310,420)));
  perform tests.check('H1 shadow ban returns ok=true', v_res->>'ok', 'true');
  perform tests.check('H2 shadow ban flag present',  v_res->>'shadow', 'true');
end $$;

select tests.check('H3 shadow-banned write was silently dropped',
  (select count(*)::text from public.territories where cell_id='892830eee000001'), '0');

-- ===========================================================================
-- GROUP I — territory customisation authorisation
-- ===========================================================================
\echo ''
\echo '--- I. CUSTOMISATION ------------------------------------------------'
truncate public.territories, public.user_cell_influence cascade;
do $$ begin perform set_config('test.uid','11111111-1111-1111-1111-111111111111',false); end $$;
select public.claim_cells(gen_random_uuid(),
  jsonb_build_array(tests.cell('892830fff000001',34.18,73.23,400,310,420)));

select tests.check('I1 owner can rename',
  public.update_territory('892830fff000001','Hilltop Ridge','#22c55e')->>'ok', 'true');

select tests.check('I2 name persisted',
  (select name from public.territories where cell_id='892830fff000001'), 'Hilltop Ridge');

do $$ begin perform set_config('test.uid','22222222-2222-2222-2222-222222222222',false); end $$;
select tests.check('I3 non-owner cannot rename',
  public.update_territory('892830fff000001','Stolen','#000000')->>'error', 'not_owner');

do $$ begin perform set_config('test.uid','11111111-1111-1111-1111-111111111111',false); end $$;
select tests.check('I4 bad colour rejected',
  public.update_territory('892830fff000001','X','red')->>'error', 'bad_color');

-- ===========================================================================
-- SUMMARY
-- ===========================================================================
\echo ''
\echo '===================================================================='
select case when failures = 0
         then 'ALL TESTS PASSED'
         else failures || ' TEST(S) FAILED' end as result
from tests.state;
