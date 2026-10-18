-- Post-init script for public.ecr.aws/supabase/postgres. The image's
-- docker-entrypoint-initdb.d/migrate.sh runs this file once, after its own
-- init scripts and migrations, as supabase_admin with PGPASSWORD, JWT_SECRET
-- and JWT_EXP in the environment. It mirrors the SQL the Supabase CLI injects
-- for `supabase start`, which is what produced the dump we restore.
\set pgpass `echo "$PGPASSWORD"`
\set jwt_secret `echo "$JWT_SECRET"`
\set jwt_exp `echo "$JWT_EXP"`

ALTER DATABASE postgres SET "app.settings.jwt_secret" TO :'jwt_secret';
ALTER DATABASE postgres SET "app.settings.jwt_exp" TO :'jwt_exp';

ALTER USER postgres WITH PASSWORD :'pgpass';
ALTER USER authenticator WITH PASSWORD :'pgpass';
ALTER USER pgbouncer WITH PASSWORD :'pgpass';
ALTER USER supabase_auth_admin WITH PASSWORD :'pgpass';
ALTER USER supabase_storage_admin WITH PASSWORD :'pgpass';
ALTER USER supabase_replication_admin WITH PASSWORD :'pgpass';
ALTER USER supabase_read_only_user WITH PASSWORD :'pgpass';

-- Schemas the dump's `public` objects may reference and which the image does
-- not create on its own. Realtime / functions services are not run here.
CREATE SCHEMA IF NOT EXISTS _realtime;
ALTER SCHEMA _realtime OWNER TO postgres;
CREATE SCHEMA IF NOT EXISTS private;
ALTER SCHEMA private OWNER TO postgres;
CREATE SCHEMA IF NOT EXISTS supabase_migrations;
ALTER SCHEMA supabase_migrations OWNER TO postgres;
