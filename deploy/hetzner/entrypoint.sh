#!/bin/sh
# Container entrypoint: feed the deployment env to the worker and start Wrangler's
# local runtime. Wrangler only injects worker variables from the config file or a
# `.dev.vars` file beside it, never from the process environment, so the mounted
# secret file is copied there first (tmpfs-free, mode 600, owned by this user).
set -eu

SECRETS_FILE="${BENTO_ENV_FILE:-/run/secrets/bento_env}"
if [ ! -r "$SECRETS_FILE" ]; then
  echo "bento-entrypoint: cannot read $SECRETS_FILE (mount /opt/bento/secrets/bento.env there)" >&2
  exit 1
fi
install -m 600 "$SECRETS_FILE" /app/.dev.vars

# The https scheme behind nginx and the /__scheduled cron trigger are handled by
# deploy/hetzner/vm-entry.mjs (the config's `main`), not by wrangler flags:
# --test-scheduled cannot inject its facade into a `no_bundle` worker, and
# --local-upstream/--upstream-protocol did not change request.url in testing.
# --persist-to /data: R2 objects, queue messages and rate-limit state survive restarts.
exec wrangler dev \
  --config /app/wrangler.server.jsonc \
  --local \
  --ip 0.0.0.0 \
  --port 8787 \
  --persist-to /data \
  --show-interactive-dev-session false \
  --log-level "${WRANGLER_LOG_LEVEL:-info}"
