import { readFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  assertSocialOAuthRedirectMatchesEnvironment,
  authorizationUrl,
  facebookPageIdsFromTokenDebug,
  normalizedSocialConnectionScopes,
  resolveSocialAccountSelection,
  socialProviderCredentialsConfigured,
  socialProviderReadiness,
  socialProviderRedirectUri,
  socialProviderRequestedScopes,
} from "./social-oauth.functions";

const ENV_KEYS = [
  "VITE_APP_URL",
  "META_INSTAGRAM_APP_ID",
  "META_INSTAGRAM_APP_SECRET",
  "META_FACEBOOK_APP_ID",
  "META_FACEBOOK_APP_SECRET",
  "META_FACEBOOK_PUBLISHING_ONLY",
  "REDDIT_CLIENT_ID",
  "REDDIT_CLIENT_SECRET",
  "LINKEDIN_CLIENT_ID",
  "LINKEDIN_CLIENT_SECRET",
  "SOCIAL_CONNECTION_ENCRYPTION_KEY",
  "THREADS_PROFILE_DISCOVERY_APPROVED",
] as const;

const originalEnvironment = Object.fromEntries(ENV_KEYS.map((key) => [key, process.env[key]]));

function setEnvironment(name: (typeof ENV_KEYS)[number], value: string) {
  process.env[name] = value;
}

afterEach(() => {
  for (const key of ENV_KEYS) {
    const originalValue = originalEnvironment[key];
    if (originalValue === undefined) delete process.env[key];
    else process.env[key] = originalValue;
  }
});

describe("social provider credential readiness", () => {
  it("queues the initial Insights import after generic and Instagram connections persist", () => {
    expect(
      readFileSync(join(process.cwd(), "src/lib/social-oauth.functions.ts"), "utf8"),
    ).toContain("queueInitialSocialInsightsImport");
    expect(
      readFileSync(join(process.cwd(), "src/lib/social-connections.functions.ts"), "utf8"),
    ).toContain("queueInitialSocialInsightsImport");
  });
  it("reuses the published Meta app for Facebook Pages", () => {
    setEnvironment("META_INSTAGRAM_APP_ID", "meta-app");
    setEnvironment("META_INSTAGRAM_APP_SECRET", "meta-secret");

    expect(socialProviderCredentialsConfigured("facebook")).toBe(true);
  });

  it("prefers but does not require dedicated Facebook credentials", () => {
    setEnvironment("META_FACEBOOK_APP_ID", "facebook-app");
    setEnvironment("META_FACEBOOK_APP_SECRET", "facebook-secret");

    expect(socialProviderCredentialsConfigured("facebook")).toBe(true);
  });

  it("reuses the published Meta app for Threads", () => {
    setEnvironment("META_INSTAGRAM_APP_ID", "meta-app");
    setEnvironment("META_INSTAGRAM_APP_SECRET", "meta-secret");

    expect(socialProviderCredentialsConfigured("threads")).toBe(true);
  });

  it("never combines credentials from two different Meta app pairs", () => {
    setEnvironment("META_FACEBOOK_APP_ID", "partial-facebook-app");
    setEnvironment("META_INSTAGRAM_APP_SECRET", "partial-instagram-secret");

    expect(socialProviderCredentialsConfigured("facebook")).toBe(false);
  });

  it("reports Reddit readiness when its official API credentials are configured", () => {
    setEnvironment("REDDIT_CLIENT_ID", "reddit-client");
    setEnvironment("REDDIT_CLIENT_SECRET", "reddit-secret");
    setEnvironment("SOCIAL_CONNECTION_ENCRYPTION_KEY", "a".repeat(64));

    expect(socialProviderReadiness().reddit).toBe(true);
  });

  it("keeps a provider locked if either credential is missing", () => {
    setEnvironment("LINKEDIN_CLIENT_ID", "linkedin-client");

    expect(socialProviderCredentialsConfigured("linkedin")).toBe(false);
  });

  it("preserves requested permissions when a token response omits scope", () => {
    expect(normalizedSocialConnectionScopes("threads", undefined)).toEqual([
      "threads_basic",
      "threads_content_publish",
      "threads_manage_insights",
    ]);
    expect(normalizedSocialConnectionScopes("linkedin", "openid w_member_social")).toEqual([
      "openid",
      "w_member_social",
    ]);
    expect(socialProviderRequestedScopes("reddit")).toContain("submit");
  });

  it("requests Threads profile discovery only after its permission is approved", () => {
    delete process.env.THREADS_PROFILE_DISCOVERY_APPROVED;
    expect(socialProviderRequestedScopes("threads")).not.toContain("threads_profile_discovery");
    setEnvironment("THREADS_PROFILE_DISCOVERY_APPROVED", "true");
    expect(socialProviderRequestedScopes("threads")).toContain("threads_profile_discovery");
  });

  it("requests only LinkedIn sign-in and publishing scopes", () => {
    expect(socialProviderRequestedScopes("linkedin")).toEqual([
      "openid",
      "profile",
      "w_member_social",
    ]);
  });

  it("requests YouTube channel analytics access", () => {
    expect(socialProviderRequestedScopes("youtube")).toContain(
      "https://www.googleapis.com/auth/yt-analytics.readonly",
    );
  });

  it("requests only the TikTok scopes used by Direct Post and Social Insights", () => {
    expect(socialProviderRequestedScopes("tiktok")).toEqual([
      "user.info.basic",
      "user.info.stats",
      "video.list",
      "video.publish",
    ]);
  });

  it("requests Facebook Page publishing and Messenger scopes together", () => {
    delete process.env.META_FACEBOOK_PUBLISHING_ONLY;
    expect(socialProviderRequestedScopes("facebook")).toEqual([
      "pages_show_list",
      "pages_read_user_content",
      "pages_read_engagement",
      "pages_manage_posts",
      "pages_manage_metadata",
      "pages_manage_engagement",
      "pages_messaging",
      "read_insights",
    ]);
  });

  it("limits the Facebook consent URL and missing-scope fallback to publishing and insights", () => {
    setEnvironment("META_FACEBOOK_PUBLISHING_ONLY", "true");
    setEnvironment("VITE_APP_URL", "http://localhost:8080");
    const url = new URL(authorizationUrl("facebook", "app-id", "oauth-state", ""));
    const scopes = [
      "pages_show_list",
      "pages_read_engagement",
      "pages_manage_posts",
      "read_insights",
    ];

    expect(url.searchParams.get("scope")?.split(",")).toEqual(scopes);
    expect(url.searchParams.get("redirect_uri")).toBe(
      "http://localhost:8080/integrations/social/facebook/callback",
    );
    expect(url.searchParams.get("state")).toBe("oauth-state");
    expect(normalizedSocialConnectionScopes("facebook", undefined)).toEqual(scopes);
    expect(normalizedSocialConnectionScopes("facebook", "pages_show_list")).toEqual([
      "pages_show_list",
    ]);
  });

  it("keeps the publishing-only option scoped to Facebook and preserves the default when off", () => {
    setEnvironment("META_FACEBOOK_PUBLISHING_ONLY", "true");
    expect(socialProviderRequestedScopes("twitter")).toContain("dm.write");
    setEnvironment("META_FACEBOOK_PUBLISHING_ONLY", "false");
    expect(socialProviderRequestedScopes("facebook")).toContain("pages_messaging");
  });

  it("requests X posting and Direct Message scopes together", () => {
    expect(socialProviderRequestedScopes("twitter")).toEqual([
      "tweet.read",
      "tweet.write",
      "users.read",
      "offline.access",
      "media.write",
      "like.read",
      "dm.read",
      "dm.write",
    ]);
  });

  it("builds the exact production LinkedIn callback URL", () => {
    setEnvironment("VITE_APP_URL", "https://app.example.com/");

    expect(socialProviderRedirectUri("linkedin")).toBe(
      "https://app.example.com/integrations/social/linkedin/callback",
    );
  });

  it("builds the exact staging LinkedIn callback URL", () => {
    setEnvironment("VITE_APP_URL", "https://app.test.example.com");

    expect(socialProviderRedirectUri("linkedin")).toBe(
      "https://app.test.example.com/integrations/social/linkedin/callback",
    );
  });

  it("rejects an OAuth callback started in a different Bento environment", () => {
    setEnvironment("VITE_APP_URL", "https://app.test.example.com");

    expect(() =>
      assertSocialOAuthRedirectMatchesEnvironment(
        "linkedin",
        "https://app.example.com/integrations/social/linkedin/callback",
      ),
    ).toThrow("different Bento environment");
  });
});

describe("social account selection", () => {
  const pages = [
    { id: "1240941709105885", name: "Intrvuer", token: "page-token-1" },
    { id: "352329328293863", name: "EduClick Africa", token: "page-token-2" },
    { id: "545211408668106", name: "TechDirect CM", token: "page-token-3" },
  ];

  it("asks the creator to choose when one grant returns more accounts than a workspace keeps", () => {
    // Before this, the first Page Meta listed was stored silently, so a workspace
    // meant for another Page kept reconnecting to the wrong one.
    expect(resolveSocialAccountSelection(pages)).toEqual({ accounts: [], selectionRequired: true });
  });

  it("keeps a single discovered account without asking", () => {
    expect(resolveSocialAccountSelection(pages.slice(1, 2))).toEqual({
      accounts: [pages[1]],
      selectionRequired: false,
    });
  });

  it("keeps exactly the chosen account and nothing for an unknown choice", () => {
    expect(resolveSocialAccountSelection(pages, "352329328293863")).toEqual({
      accounts: [pages[1]],
      selectionRequired: false,
    });
    expect(resolveSocialAccountSelection(pages, "not-granted")).toEqual({
      accounts: [],
      selectionRequired: false,
    });
  });
});

describe("Facebook Page discovery from the token debugger", () => {
  it("reads the Pages a narrowed grant covers, publishing scope first", () => {
    // Seen on 2026-10-18: /me/accounts returned [] for a grant limited to two
    // of three Pages, while each granted Page was still readable directly.
    expect(
      facebookPageIdsFromTokenDebug({
        data: {
          granular_scopes: [
            { scope: "pages_show_list", target_ids: ["545211408668106", "352329328293863"] },
            { scope: "pages_manage_posts", target_ids: ["352329328293863", "545211408668106"] },
          ],
        },
      }),
    ).toEqual(["352329328293863", "545211408668106"]);
  });

  it("falls back to the listing scope and ignores malformed input", () => {
    expect(
      facebookPageIdsFromTokenDebug({
        data: { granular_scopes: [{ scope: "pages_show_list", target_ids: [123, "x", 123] }] },
      }),
    ).toEqual(["123"]);
    expect(
      facebookPageIdsFromTokenDebug({
        data: { granular_scopes: [{ scope: "pages_manage_posts" }] },
      }),
    ).toEqual([]);
    expect(facebookPageIdsFromTokenDebug(null)).toEqual([]);
    expect(facebookPageIdsFromTokenDebug({ error: { message: "bad token" } })).toEqual([]);
  });
});
