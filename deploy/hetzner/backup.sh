#!/usr/bin/env bash
# Nightly local backup of the Bento stack: a pg_dump of bento_db plus a tarball
# of the bento_state volume (R2 media, queue and rate-limit state). Keeps 14 days.
#
# Cron (deploy user):  30 2 * * * /opt/bento/src/deploy/hetzner/backup.sh >> /opt/bento/backups/backup.log 2>&1
#
# These copies live on the VM. Off-host copies are a follow-up (the VM has no
# aws CLI today); until then treat this as protection against bad deploys and
# operator mistakes, not against losing the host.
set -Eeuo pipefail

BENTO_HOME="${BENTO_HOME:-/opt/bento}"
out="$BENTO_HOME/backups"
keep_days="${BENTO_BACKUP_KEEP_DAYS:-14}"
ts="$(date -u +%Y%m%dT%H%M%SZ)"
install -d -m 700 "$out"

db_file="$out/bento-db-$ts.dump"
# Dump inside the container, prove pg_restore can read its TOC (a torn dump
# fails here), then copy it out. pg_restore cannot list a custom-format dump
# arriving on a pipe, hence the temp file.
docker exec bento_db sh -c 'pg_dump -U supabase_admin -Fc --no-password -f /tmp/bento-backup.dump postgres && pg_restore -l /tmp/bento-backup.dump > /dev/null'
docker cp bento_db:/tmp/bento-backup.dump "$db_file.part"
docker exec bento_db rm -f /tmp/bento-backup.dump
chmod 600 "$db_file.part"
mv "$db_file.part" "$db_file"

state_file="$out/bento-state-$ts.tgz"
docker run --rm -v bento_state:/data:ro -v "$out:/out" alpine:3.20 \
  tar czf "/out/$(basename "$state_file").part" -C /data .
mv "$state_file.part" "$state_file"

find "$out" -type f \( -name 'bento-db-*.dump' -o -name 'bento-state-*.tgz' \) -mtime "+$keep_days" -delete
echo "$ts ok db=$(du -h "$db_file" | cut -f1) state=$(du -h "$state_file" | cut -f1)"
