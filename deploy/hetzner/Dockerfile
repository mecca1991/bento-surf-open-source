# syntax=docker/dockerfile:1.7
#
# Bento Surf for a plain Linux VM.
#
# Stage 1 builds the exact Cloudflare Worker bundle Bento ships (`bun run build`
# = vite build + scripts/write-worker-entry.ts). VITE_* values are inlined at
# build time from `.env`, so the deployment env file is mounted as a BuildKit
# secret under that name and never lands in an image layer.
#
# Stage 2 runs that bundle under Wrangler's local runtime (workerd + Miniflare):
# real Queues, R2, rate limiters and cron, persisted under /data. See
# deploy/hetzner/README.md for why this is used instead of Cloudflare.
#
# Build (from the repository root):
#   docker build -f deploy/hetzner/Dockerfile \
#     --secret id=bento_env,src=/opt/bento/secrets/bento.env -t bento-app:local .

FROM oven/bun:1.3.14-debian AS build
WORKDIR /app
COPY package.json bun.lock bunfig.toml ./
RUN bun install --frozen-lockfile
COPY . .
# `required=true` fails the build loudly instead of silently baking localhost URLs.
RUN --mount=type=secret,id=bento_env,target=/app/.env,required=true \
    bun run build

FROM node:22-bookworm-slim AS runtime
# ca-certificates: outbound HTTPS from the worker (Supabase, Meta Graph API).
# wget: container healthcheck.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates wget \
 && rm -rf /var/lib/apt/lists/*
# Pinned to the wrangler version in bun.lock; it bundles the matching workerd.
RUN npm install -g wrangler@4.111.0 && npm cache clean --force

WORKDIR /app
COPY --from=build --chown=node:node /app/.output ./.output
# VM-specific worker entry (scheme rewrite behind nginx + token-gated cron
# trigger); wraps the generated .output/server/worker.mjs.
COPY --chown=node:node deploy/hetzner/vm-entry.mjs ./.output/server/vm-entry.mjs
COPY --chown=node:node deploy/hetzner/wrangler.server.jsonc ./wrangler.server.jsonc
COPY --chmod=755 deploy/hetzner/entrypoint.sh /usr/local/bin/bento-entrypoint

# uid 1000 (`node`) matches the `deploy` user on the VM, so the bind-mounted
# secret file (deploy-owned, mode 600) is readable without widening its mode.
RUN mkdir -p /data /app/.wrangler && chown -R node:node /app /data
USER node
ENV NODE_ENV=production \
    WRANGLER_SEND_METRICS=false \
    CI=1 \
    HOME=/home/node

EXPOSE 8787
VOLUME ["/data"]
HEALTHCHECK --interval=30s --timeout=10s --start-period=90s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8787/robots.txt >/dev/null || exit 1
ENTRYPOINT ["bento-entrypoint"]
