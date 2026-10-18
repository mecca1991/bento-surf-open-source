#!/usr/bin/env bash
# Restore the laptop's Supabase pg_dump (custom format) into a FRESH bento_db.
#
#   ./restore-from-dump.sh /opt/bento/local-marketing-20261018.dump
#
# Must run BEFORE bento_auth ever starts: the dump carries auth.schema_migrations
# at the same GoTrue version (v2.197.0), so GoTrue then has nothing to migrate.
# Only the application schemas are restored (public, auth, private,
# supabase_migrations). Extensions and the Supabase-managed schemas (storage,
# realtime, vault, cron, graphql, ...) already exist in the image and are left
# alone. Ownership is preserved so supabase_auth_admin / authenticator keep
# working. `--clean --if-exists` makes a re-run on the same volume idempotent.
set -Eeuo pipefail

dump="${1:?usage: restore-from-dump.sh <file.dump>}"
[[ -r "$dump" ]] || { echo "cannot read $dump" >&2; exit 1; }
container="${BENTO_DB_CONTAINER:-bento_db}"

docker inspect -f '{{.State.Health.Status}}' "$container" | grep -qx healthy \
  || { echo "$container is not healthy; start it first (make up-db)" >&2; exit 1; }
if docker ps --format '{{.Names}}' | grep -qx bento_auth; then
  echo "bento_auth is running; stop it first (docker compose stop bento_auth) so GoTrue does not race the restore" >&2
  exit 1
fi

echo "copying dump into $container ..."
docker cp "$dump" "$container:/tmp/bento-restore.dump"

echo "restoring public, auth, private, supabase_migrations ..."
log="$(mktemp)"
set +e
docker exec "$container" pg_restore \
  -U supabase_admin -d postgres \
  --clean --if-exists --no-password \
  -n public -n auth -n private -n supabase_migrations \
  /tmp/bento-restore.dump >"$log" 2>&1
status=$?
set -e
docker exec "$container" rm -f /tmp/bento-restore.dump

# pg_restore exits 1 whenever any statement errored. The expected noise is the
# schema/role objects that already exist in the image; anything else is a
# real problem and is printed for review.
expected='already exists|does not exist, skipping|must be owner of|cannot drop schema auth|DROP SCHEMA'
unexpected="$(grep -E '^pg_restore: error' "$log" | grep -Ev "$expected" || true)"
echo "pg_restore exit $status; $(grep -c '^pg_restore: error' "$log" || true) error lines, $(printf '%s' "$unexpected" | grep -c . || true) unexpected"
if [[ -n "$unexpected" ]]; then
  echo "---- unexpected errors ----"
  printf '%s\n' "$unexpected" | head -40
  echo "full log: $log"
fi

echo "verifying ..."
docker exec "$container" psql -U supabase_admin -d postgres -At <<'SQL'
select 'schema_migrations='||count(*) from supabase_migrations.schema_migrations;
select 'auth_users='||count(*) from auth.users;
select 'profiles='||count(*) from public.profiles;
select 'workspace_memberships='||count(*) from public.workspace_memberships;
select 'social_connections='||count(*) from public.social_connections;
select 'social_posts='||count(*) from public.social_posts;
select 'creator_brain_items='||count(*) from public.creator_brain_items;
SQL
echo "expected from the 2026-10-18 dump: schema_migrations=219 auth_users=1 profiles=2 workspace_memberships=2 social_connections=1 social_posts=8 creator_brain_items=20"
[[ -z "$unexpected" ]] && rm -f "$log"
