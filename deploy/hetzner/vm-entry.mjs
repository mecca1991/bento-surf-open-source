// Worker entry for the VM deployment. Wraps Bento's generated worker.mjs
// (scripts/write-worker-entry.ts) with two adaptations that only matter when
// the Worker runs behind our own reverse proxy instead of on Cloudflare:
//
// 1. Scheme. nginx terminates TLS and forwards plain HTTP, so workerd builds
//    request.url as http://<host>/... Bento's canonical-host routing then
//    redirects to https, which comes back as http again: an infinite loop.
//    nginx sets X-Forwarded-Proto, so the URL is rewritten to https here before
//    Bento sees it. Requests from inside shared_network (no header) are untouched.
//
// 2. Cron. Cloudflare invokes scheduled() itself; here the bento_cron sidecar
//    calls GET /__scheduled?cron=<expr> with a shared token and this entry
//    forwards to Bento's scheduled() with the same controller shape. Wrangler's
//    own --test-scheduled facade is not available with `no_bundle`, which this
//    worker requires. The route needs BENTO_CRON_TOKEN and nginx blocks it from
//    the internet as well.
//
// Copied into .output/server/ by deploy/hetzner/Dockerfile; referenced as
// `main` by deploy/hetzner/wrangler.server.jsonc.
import worker from "./worker.mjs";

const SCHEDULED_PATH = "/__scheduled";

function tokenMatches(expected, given) {
  if (typeof expected !== "string" || expected.length < 32 || typeof given !== "string") return false;
  if (expected.length !== given.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) diff |= expected.charCodeAt(i) ^ given.charCodeAt(i);
  return diff === 0;
}

async function runScheduled(request, env, ctx) {
  if (!tokenMatches(env.BENTO_CRON_TOKEN, request.headers.get("x-bento-cron-token"))) {
    return new Response("forbidden", { status: 403 });
  }
  const url = new URL(request.url);
  const cron = url.searchParams.get("cron") ?? "* * * * *";
  const controller = { cron, scheduledTime: Date.now(), noRetry() {} };
  const started = Date.now();
  try {
    await worker.scheduled(controller, env, ctx);
  } catch (error) {
    console.error(`[vm-entry] scheduled(${cron}) failed`, error);
    return new Response(`scheduled(${cron}) failed: ${error?.message ?? error}`, { status: 500 });
  }
  return new Response(`ran scheduled(${cron}) in ${Date.now() - started}ms\n`, { status: 200 });
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname === SCHEDULED_PATH) return runScheduled(request, env, ctx);

    if (request.headers.get("x-forwarded-proto") === "https" && url.protocol !== "https:") {
      url.protocol = "https:";
      request = new Request(url.toString(), request);
    }
    return worker.fetch(request, env, ctx);
  },
  queue(batch, env, ctx) {
    return worker.queue(batch, env, ctx);
  },
  scheduled(controller, env, ctx) {
    return worker.scheduled(controller, env, ctx);
  },
};
