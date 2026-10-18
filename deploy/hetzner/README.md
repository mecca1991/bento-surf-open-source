# Bento Surf on the Hetzner VM

Self-hosted Bento for the EduClick + Intrvuer marketing pilot, running on the
shared Hetzner VM (`95.217.228.179`) next to the EduClick and Intrvuer APIs.
Public URL: `https://bento.wilfredchetat.com`.

## Why Wrangler's local runtime

Bento's server is compiled as a Cloudflare Worker (`fetch` + `queue` +
`scheduled` handlers; R2, 14 Queues, 6 rate limiters, Images). Every binding
reaches the code through `globalThis.__env__`, and nothing imports
`cloudflare:*` modules. Running the **unmodified production build** under
`wrangler dev --local` (workerd + Miniflare) therefore gives real Queues with
ack/retry/delay/dead-letter semantics, persisted R2, rate limiters and the
`scheduled()` handler with zero code changes. The alternative, porting to a Node
server, means re-implementing those bindings (several hundred lines of shims).

Trade-offs, all accepted for a one-operator pilot:

- `wrangler dev` is a development server used as the runtime. One process; a
  restart is `make restart s=bento_app`; state in the `bento_state` volume survives.
- No Workers AI / Browser Rendering: AI text falls back to Groq or OpenRouter
  (keys optional, budgets disabled); OG images are static; X link previews
  report "blocked". Cloudflare Images runs locally via Miniflare's `images` plugin.
- `vm-entry.mjs` wraps the generated worker: it rewrites the request scheme to
  https when nginx says so (`X-Forwarded-Proto`), because workerd otherwise
  builds `http://` URLs and Bento's canonical-host routing would loop, and it
  serves the token-gated `/__scheduled` route the `bento_cron` sidecar calls
  (Wrangler's `--test-scheduled` facade cannot be injected into a `no_bundle`
  worker). The shared nginx blocks `/__scheduled` publicly.
- Wrangler's dev proxy rewrites same-host `Location` headers to plain http; the
  shared nginx restores https with `proxy_redirect` (verified in a local smoke test).
- Wrangler version is pinned in the Dockerfile; its bundled workerd caps the
  compatibility date (2026-07-17 today), so `wrangler.server.jsonc` pins that
  instead of the root config's 2026-09-01. Upgrade both together, deliberately.

## Components

```
Internet ──443──> shared nginx (server-infra)   host bento.wilfredchetat.com
   /supabase/*  ──> bento_gateway:8000  nginx:alpine, Kong stand-in (apikey check + path routing)
                       /auth/v1/* ─> bento_auth:9999  supabase/gotrue v2.197.0
                       /rest/v1/* ─> bento_rest:3000  supabase/postgrest v16.4
   /*           ──> bento_app:8787      wrangler dev --local  (SUPABASE_URL=http://bento_gateway:8000)
                       ├─ /data volume bento_state: R2 objects, queues, rate-limit state
                       └─ bento_cron: GET /__scheduled every minute + 09:00 UTC
bento_db  supabase/postgres:15.19.0.004  volume bento_pg, published on 127.0.0.1:54322 only
```

Everything joins server-infra's external `shared_network`. The Supabase trio
runs the exact images the Supabase CLI uses on the laptop, so the laptop's
`pg_dump` restores 1:1. Realtime, Storage, Kong, Studio and Edge Runtime are not
run: Bento uses only Auth and PostgREST, and the laptop setup already excluded them.
Supabase is served under the app's own origin (`/supabase/`) because Bento's
production CSP only allows `connect-src 'self' https://*.supabase.co`.

## Layout on the VM

```
/opt/bento/
  src/            rsync of this repository (no node_modules/.artifacts/.env)
  secrets/        compose.env + bento.env   (mode 600, owner deploy; never in git)
  backups/        nightly dumps from backup.sh
  *.dump          the laptop dump used for the initial restore
```

Compose project `bento`; volumes `bento_pg`, `bento_state`.

## First deployment

1. DNS: `bento.wilfredchetat.com  A  95.217.228.179` (Route 53).
2. Sync the repo (from the laptop):
   ```sh
   rsync -az --delete --exclude node_modules --exclude .artifacts --exclude .output \
     --exclude .wrangler --exclude .tanstack --exclude .git --exclude '.env*' --exclude '.dev.vars*' \
     ~/Documents/bento-surf-open-source/ deploy@95.217.228.179:/opt/bento/src/
   scp ~/Documents/bento-surf-open-source/.artifacts/local-marketing-20261018.dump deploy@95.217.228.179:/opt/bento/
   ```
3. Secrets, on the VM as `deploy`:
   ```sh
   cd /opt/bento/src/deploy/hetzner
   BENTO_PUBLIC_HOST=bento.wilfredchetat.com ./init-secrets.sh
   # fill the __CARRY_OVER__ values in /opt/bento/secrets/bento.env from the laptop .env:
   #   SOCIAL_CONNECTION_ENCRYPTION_KEY, META_FACEBOOK_APP_ID, META_FACEBOOK_APP_SECRET
   make check
   ```
   The laptop stack uses Supabase's publicly known demo JWT secret and keys;
   they are never reused. Sessions are re-created at first login; the
   password hash in `auth.users` stays valid.
4. Database: `make up-db`, wait for `healthy`, then
   `make restore dump=/opt/bento/local-marketing-20261018.dump`. Expected counts
   are printed by the script (219 migrations, 1 user, 2 profiles, 1 social
   connection, 8 social posts). Then `make up` for the rest.
5. App image: `make build` (12 cores, several minutes; `bun install` +
   `vite build`), then `make up`. Check `docker exec bento_app wget -qO- http://127.0.0.1:8787/robots.txt`.
6. nginx + TLS: add the `bento.wilfredchetat.com` vhost to
   `/opt/server-infra/nginx/nginx.conf` (port-80 block first for the ACME
   challenge), `make -C /opt/server-infra nginx-test nginx-reload`, issue the
   certificate with the same image/webroot `scripts/renew-certificates.sh` uses,
   add the 443 block, test and reload again. The nightly renew job then covers it.
7. After the first successful login set `BENTO_AUTH_DISABLE_SIGNUP=true` in
   `compose.env` and `make up` (recreates `bento_auth` only).
8. Meta app: add `https://bento.wilfredchetat.com/integrations/social/facebook/callback`
   to the Valid OAuth Redirect URIs. Needed only for future reconnects; the
   stored Page token keeps publishing.
9. Backups: `crontab -e` as `deploy`:
   `30 2 * * * /opt/bento/src/deploy/hetzner/backup.sh >> /opt/bento/backups/backup.log 2>&1`

## Updating the app

```sh
rsync ... (as above)          # new source
make -C /opt/bento/src/deploy/hetzner build up
```
`.output` is rebuilt inside the image; `VITE_*` values come from
`secrets/bento.env` at build time, so a URL change needs a rebuild, not just a restart.

New SQL migrations: run on the VM, where the wrapper's `--local` guard matches
(`127.0.0.1:54322`, user `postgres`):
```sh
cd /opt/bento/src && APP_ENV=development MIGRATION_CONFIRMATION=MIGRATE:bento-surf \
  bun scripts/migrate-supabase.ts --local --dry-run     # needs bun + supabase CLI on the VM
```
Until those tools are installed on the VM, apply a reviewed migration file with
`make psql < supabase/migrations/<file>.sql` and insert its version into
`supabase_migrations.schema_migrations`.

## Operations

| Task | Command |
|---|---|
| Status / logs | `make ps`, `make logs s=bento_app` |
| Cron firing? | `make logs s=bento_cron` (silent = ok; failures print a line) and `make logs s=bento_app` for `scheduled` entries |
| Restart app | `make restart s=bento_app` |
| DB shell | `make psql` |
| Backup now | `make backup` |
| Restore a backup | stop `bento_auth`, `make restore dump=/opt/bento/backups/bento-db-<ts>.dump`, `make up` |
| Rotate app secrets | edit `secrets/bento.env`, `make build up` (VITE_* are baked) or `make restart s=bento_app` (runtime-only keys) |

Do not rotate `SOCIAL_CONNECTION_ENCRYPTION_KEY` or the JWT secret without a
plan: the first makes every stored social token unreadable (reconnect required),
the second invalidates all sessions and requires re-minting the anon and
service_role keys in both env files.

## Known limitations

- Recovery mail depends on the `BENTO_SMTP_*` relay in `compose.env` (Mailjet, the
  same API key/secret EduClick uses, sender `no-reply@educlick.africa`). The
  restored account's address (`marketing@example.test`) is not a real mailbox, so
  change it first through the GoTrue admin API (`PUT /auth/v1/admin/users/{id}`
  with `email`, `password`, `email_confirm: true`, service-role key as apikey and
  bearer) before relying on "Forgot password?".
- Sign-up is closed after step 7. `/signup` on the public site errors by design.
- MCP OAuth (`auth.oauth.*`) is not enabled on self-hosted GoTrue.
- `/api/health` reports 503 because Dodo, Polar, Browser Rendering and other
  Cloudflare-only pieces are unconfigured; use `/robots.txt` as the liveness probe.
- Rate-limit keys use `CF-Connecting-IP`, which the shared nginx sets from the
  client address (workerd passes it through unchanged).
- Backups stay on the VM until an off-host copy is wired (no `aws` CLI on the host).
