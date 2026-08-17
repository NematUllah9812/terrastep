-- Local test shim: emulates the parts of Supabase we depend on, so
-- 01_DATA_MODEL.sql and 02_CLAIM_ENGINE.sql can be run on vanilla Postgres.
-- NOT for production. Production runs the real files unmodified.

create schema if not exists auth;
create schema if not exists realtime;
create schema if not exists extensions;
create schema if not exists cron;

create table if not exists auth.users (
  id uuid primary key default gen_random_uuid(),
  email text,
  raw_user_meta_data jsonb default '{}'::jsonb
);

-- Session-scoped current user, settable per test
create or replace function auth.uid() returns uuid
language sql stable as $$
  select nullif(current_setting('test.uid', true), '')::uuid;
$$;

-- no-op realtime
create or replace function realtime.send(
  payload jsonb, event text, topic text, private boolean default false)
returns void language plpgsql as $$
begin
  raise notice 'REALTIME[%] % -> %', topic, event, payload;
end $$;

-- no-op cron
create or replace function cron.schedule(job_name text, sched text, cmd text)
returns bigint language sql as $$ select 1::bigint $$;

-- Minimal PostGIS stand-ins (we only use st_point / geography for a centroid)
do $$ begin
  if not exists (select 1 from pg_type where typname = 'geography') then
    create domain geography as text;
  end if;
end $$;

create or replace function st_point(lng float8, lat float8)
returns text language sql immutable as $$ select lng::text || ',' || lat::text $$;

-- roles used by GRANT statements
do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role; end if;
end $$;
