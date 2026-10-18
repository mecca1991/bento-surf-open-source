# Local marketing setup

Verified 18 October 2026 on macOS arm64. Base commit: `d267a568994e739f81bcb734d9ba1ffe560583e2`. Local changes are on `chore/local-marketing-pilot`; nothing has been committed or pushed.

## What runs here

Bento is a React/TanStack Start application. The browser calls authenticated server functions; those functions resolve the active workspace and use Supabase for auth and Postgres data. A workspace's Brain holds profile, voice, instructions, sources and strategy. The existing Post Scheduler stores drafts, connections and publication state.

This setup runs the UI and server functions with Vite on **http://localhost:8080**, backed by a separate local Supabase project, `bento-surf`. Login, workspace switching, Brain editing and text draft creation/review work locally. This is independent of the existing EduClick and intrvuer backends and ingestion services.

| Capability | Current state / dependency |
|---|---|
| Two workspaces, Brain, text drafts | Working with local Supabase |
| Groq text generation | Existing adapter available; key absent and all provider budgets disabled |
| Facebook Page OAuth/publishing | Intrvuer connected; localhost callback and four granted scopes verified with read-only Graph calls; no post published |
| Facebook Insights | Manual refresh verified; one existing Page post imported; visitor comments/reactions excluded by the approved scope |
| Media uploads | Private Cloudflare R2 is connected through the opt-in Wrangler bridge using OAuth; upload/read/delete verified; see [R2 setup](r2-local.md) |
| Media generation/rendering | Requires the relevant configured provider/budget; remains disabled |
| Publishing and scheduled/background jobs | Cloudflare Worker queues/consumers and cron are required; Vite has no publishing queue. Non-draft publish/schedule/retry is rejected before persistence; draft creation remains available. |
| Public webhooks, hosted pages, custom domains | Need reachable infrastructure and separate deployment approval |
| Product visits/conversions | Optional PostHog changes in separate frontend worktrees; disabled and not deployed |

## Hosted instance (18 October 2026)

The pilot now runs on the shared Hetzner VM at https://bento.wilfredchetat.com with its own self-hosted Supabase; see [`deploy/hetzner/README.md`](../deploy/hetzner/README.md) for the runbook. The database there was restored from a pg_dump of this local stack taken the same day, so the two copies have diverged since: treat the local setup below as a development environment, not as the source of truth for drafts or Brain content. Local-only Supabase keys were not reused; the hosted instance has fresh secrets, and the shared `SOCIAL_CONNECTION_ENCRYPTION_KEY` keeps the Facebook connection valid.

## Start after a reboot

From the Bento repository:

```sh
export PATH="$PWD/.artifacts/tools/bin:$PWD/.artifacts/tools/node-v22.22.2-darwin-arm64/bin:$PATH"
open -a Docker
supabase start --exclude realtime,storage-api,imgproxy,edge-runtime,logflare,vector,supavisor
bun run dev --host localhost --port 8080
```

The scoped tools are Bun 1.3.14, Supabase CLI 2.121.0 and Node 22.22.2. Dependencies are already installed from `bun.lock`; use `bun install --frozen-lockfile` if they need reinstalling. Global runtimes were not replaced.

Open http://localhost:8080/post-scheduler. Local-only login details are in `.artifacts/local-account.json` (mode 600), with email `marketing@example.test`. The ignored `.env` contains local Supabase credentials, independent random signing/encryption keys and the configured Meta App ID/Secret; other external-provider secrets remain empty. Neither file belongs in Git. Vite denies web access to `.artifacts/**` and binds to localhost. After editing private environment values, restart the full `bun run dev` process: Vite's internal restart retained the launch environment during the Facebook setup.

For the Facebook pilot, `META_FACEBOOK_PUBLISHING_ONLY=true` requests only `pages_show_list`, `pages_read_engagement`, `pages_manage_posts` and `read_insights`. The default remains the upstream eight-scope request. This option affects new OAuth grants, not already granted permissions. Settings → Integrations → Social → Facebook shows Intrvuer connected. The sibling `bento-marketing/facebook-setup.md` records the verified Page asset ID, callback result, granted scopes and publication approval boundary.

Local services: Supabase API 54321, Postgres 54322, Studio 54323, test mail 54324. Text-only setup excludes optional services listed above. Docker data volumes preserve the workspaces and drafts across normal restarts. Do not use `db reset`, `stop --no-backup`, Docker volume pruning or destructive schema recreation on this populated pilot.

To stop only this setup: Ctrl-C in its Vite terminal, then `supabase stop --project-id bento-surf`. Other running Docker projects must be left alone. A local database backup is in `.artifacts/local-marketing-20261018.dump`; retain the ignored encryption/signing configuration securely with it. The nonsecret pilot draft export lives in the sibling `bento-marketing` folder.

## Migrations

All 219 migrations have been applied to the local database. Automatic application migrations and seeding at startup are disabled. For a later local schema change, review its SQL, make a database backup and run:

```sh
MIGRATION_CONFIRMATION=MIGRATE:bento-surf bun scripts/migrate-supabase.ts --local --dry-run
MIGRATION_CONFIRMATION=MIGRATE:bento-surf bun scripts/migrate-supabase.ts --local
```

The existing `.env` supplies `APP_ENV=development`, `SUPABASE_PROJECT_ID=bento-surf` and `SUPABASE_DB_URL`. The wrapper checks the configured local project, loopback hostname, database name, username and port before invoking the installed CLI. It creates and removes an isolated temporary CLI config for the explicitly authorized push. Hosted migrations retain their project-target checks; `--local` is not an override for a remote URL.

## Why the small code changes were needed

- Self-hosted workspace creation still required a hosted paid subscription, and onboarding's SQL function independently required hosted entitlement. Both now honor the server-selected `BENTO_EDITION=self_hosted`. The new SQL overload is service-role-only; legacy callers retain the hosted guard. Membership checks, transaction logic and workspace scoping remain in place.
- Shared server-function imports exposed Node builtins at browser module evaluation, preventing the dev app from loading. Namespace imports and lazy AsyncLocalStorage construction defer them until server execution. No browser crypto shim or budget bypass was added.
- Development CSP needed the exact configured local Supabase origin. That exception is limited to development and loopback requests.
- Removed an upstream hardcoded Google Analytics tag so local usage does not report to that upstream account. The optional configured analytics paths remain available.
- Local migration handling, artifact exclusion and loopback defaults make the setup repeatable. The existing Twitter webhook fallback now uses localhost instead of an upstream production domain.
- Fixed stale clock-dependent test fixtures and deployment-verifier tests that inherited the local `.env`.
- Added an opt-in Facebook publishing-only scope list so this Page publishing/Insights pilot does not require Messenger and moderation permissions.
- The integration dialog now checks the server's configured scope list, avoiding a false Reconnect warning for a valid publishing-only Page while leaving Auto-DM capability disabled.
- Facebook content import requests comments/reactions only with `pages_read_user_content`; their absence no longer prevents importing own Page posts and Insights. Unknown engagement totals and derived rates remain unavailable instead of being shown as zero.

## Verification

- Full Bento suite: **488 files, 3,682 tests passed**, with `TZ=UTC bun --no-env-file run test:run`.
- TypeScript and production build passed; current-source boundary check passed.
- Facebook connection follow-up: 56 focused OAuth/integration/UI tests, changed-file lint, TypeScript and build passed. The actual consent, localhost callback and read-only Page/grant checks succeeded. The settings dialog was verified after repairing the false Reconnect warning.
- Facebook Insights follow-up: 45 focused content/analytics/dashboard tests, changed-file lint, TypeScript and build passed. Manual refresh completed, one existing post was imported, and the dashboard shows N/A for engagement rate without comment/reaction access.
- R2 follow-up: 103 focused tests, TypeScript and build passed; no new lint errors (two existing server errors retained). Real local upload/download/range/isolation/cleanup passed, and Settings → Storage loads. See [R2 setup](r2-local.md) for the active remote mode and verified cloud connection.
- Browser signup, two-workspace onboarding, Brain saves, six draft saves, reload persistence and rejection of a foreign-workspace draft ID verified.
- Database: 219 applied migrations; six unscheduled draft posts; one Facebook connection in intrvuer; zero publication targets or Facebook automations; both workspaces onboarded with public pages unpublished; all 16 provider budget policies disabled.
- Whole-repository lint is **not green**: 41 errors and 229 warnings remain. Every error was compared against the original tracked file and also exists upstream; no new lint errors were found. The local tool/browser artifacts are excluded. See `.artifacts/lint-baseline-comparison.json`.
- History boundary check still flags upstream blob `e2273b116de9` in `src/lib/twitter-auto-dm.server.ts`; the current source is fixed, but shared history was not rewritten.
- Logs and the database backup are under ignored `.artifacts/`. A successful build is not a public deployment.

The dev router also regenerates `src/routeTree.gen.ts` with a different declaration order on this machine. Import sets and generated route-update definitions were compared and are unchanged. No routes were added. This generated ordering diff can be discarded after stopping Vite when preparing a focused commit; a running generator rewrites it.

## Facebook publishing incident follow-up

The 18 October 2026 `iv_005` publish-now attempt was reconciled to Failed after confirming no matching Facebook post existed. Its target/outbox had never been dispatched. Queue-readiness and Facebook public-media guards now prevent the misleading publishing state. Caption/media are preserved and no retry was sent. See [incident trace and verification](incidents/2026-10-18-intrvuer-facebook-iv005.md).
