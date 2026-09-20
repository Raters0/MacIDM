import assert from "node:assert/strict";
import test from "node:test";

import {
  buildRequestContext,
  originPermissionPattern,
  serializeUnpartitionedCookies,
} from "../../../BrowserExtension/chrome/src/background/request-context.js";

function browserStub({ granted, cookies, authorizedOrigins = [] }) {
  return {
    permissions: {
      async contains() {
        return granted;
      },
    },
    cookies: {
      async getAll() {
        return cookies;
      },
    },
    storage: {
      local: {
        async get(key) {
          return { [key]: authorizedOrigins };
        },
        async set() {},
      },
    },
  };
}

test("cookie context is only read after page-origin cookies permission is granted", async () => {
  const calls = [];
  const browser = {
    permissions: {
      async contains(request) {
        calls.push(request);
        return true;
      },
    },
    cookies: {
      async getAll(request) {
        calls.push(request);
        return [
          { name: "session", value: "secret", path: "/" },
          { name: "partitioned", value: "ignored", path: "/", partitionKey: {} },
        ];
      },
    },
    storage: {
      local: {
        async get(key) {
          return { [key]: ["https://example.com"] };
        },
        async set() {},
      },
    },
  };

  const { context, cookieDiagnostics } = await buildRequestContext(
    {
      url: "https://cdn.example.com/private/file.zip",
      referrer: "https://example.com/account",
    },
    browser,
  );

  assert.equal(context.cookie, "session=secret");
  assert.equal(context.referer, "https://example.com/account");
  // Site-level authorization resolves via the storage ledger; the only
  // permissions query left is the extension-scoped cookies API check.
  assert.deepEqual(calls[0], { permissions: ["cookies"] });
  assert.deepEqual(calls[1], { url: "https://example.com/account" });

  // Secure diagnostics (chrome-extension-spec §5.8): permission granted, one
  // partitioned cookie excluded, the remaining cookie attached.
  assert.equal(cookieDiagnostics.permissionGranted, true);
  assert.equal(cookieDiagnostics.cookiesFound, 2);
  assert.equal(cookieDiagnostics.partitionedExcluded, 1);
  assert.equal(cookieDiagnostics.droppedOversize, false);
  assert.equal(cookieDiagnostics.attached, true);
  assert.equal(cookieDiagnostics.cookieBytes, "session=secret".length);
});

test("referer and userAgent are attached even without cookie authorization", async () => {
  const browser = browserStub({ granted: false, cookies: [] });

  const { context, cookieDiagnostics } = await buildRequestContext(
    {
      url: "https://upos-sz-mirror.bilivideo.com/video.m4s",
      referrer: "https://www.bilibili.com/video/BV1234",
    },
    browser,
  );

  // No cookie because the user has not authorized the page origin.
  assert.equal(context.cookie, undefined);
  // Referer/UA are always present — media CDNs 403 without them.
  assert.equal(context.referer, "https://www.bilibili.com/video/BV1234");
  assert.equal(typeof context.userAgent, "string");

  // Unauthorized: permission flag recorded, nothing queried or attached.
  assert.equal(cookieDiagnostics.permissionGranted, false);
  assert.equal(cookieDiagnostics.cookiesFound, 0);
  assert.equal(cookieDiagnostics.partitionedExcluded, 0);
  assert.equal(cookieDiagnostics.droppedOversize, false);
  assert.equal(cookieDiagnostics.attached, false);
  assert.equal(cookieDiagnostics.cookieBytes, 0);
});

test("extension-wide cookies permission alone does NOT attach cookies (ledger regression)", async () => {
  // The permissions.contains bug: "cookies" is extension-scoped and the
  // manifest's global host_permissions make any origin check pass, so a
  // contains-only check silently attached cookies to every site. The ledger
  // must gate the attach path per page origin.
  const browser = browserStub({
    granted: true,
    cookies: [{ name: "session", value: "secret", path: "/" }],
    authorizedOrigins: ["https://other-site.com"],
  });

  const { context, cookieDiagnostics } = await buildRequestContext(
    {
      url: "https://cdn.example.com/file.zip",
      referrer: "https://example.com/watch",
    },
    browser,
  );

  assert.equal(context.cookie, undefined);
  assert.equal(cookieDiagnostics.permissionGranted, false);
  assert.equal(cookieDiagnostics.cookiesFound, 0);
  assert.equal(cookieDiagnostics.attached, false);
});

test("authorized page with no cookies reports found=0 and nothing attached", async () => {
  const browser = browserStub({ granted: true, cookies: [], authorizedOrigins: ["https://example.com"] });

  const { context, cookieDiagnostics } = await buildRequestContext(
    {
      url: "https://cdn.example.com/file.zip",
      referrer: "https://example.com/watch",
    },
    browser,
  );

  assert.equal(context.cookie, undefined);
  assert.equal(cookieDiagnostics.permissionGranted, true);
  assert.equal(cookieDiagnostics.cookiesFound, 0);
  assert.equal(cookieDiagnostics.attached, false);
});

test("oversize serialization is dropped and flagged in diagnostics", async () => {
  // 16 KiB budget: one cookie whose value alone exceeds it.
  const oversizeValue = "x".repeat(17 * 1024);
  const browser = browserStub({
    granted: true,
    cookies: [{ name: "bulk", value: oversizeValue, path: "/" }],
    authorizedOrigins: ["https://example.com"],
  });

  const { context, cookieDiagnostics } = await buildRequestContext(
    {
      url: "https://cdn.example.com/file.zip",
      referrer: "https://example.com/watch",
    },
    browser,
  );

  // Dropped entirely — a truncated cookie header could corrupt the parse.
  assert.equal(context.cookie, undefined);
  assert.equal(cookieDiagnostics.permissionGranted, true);
  assert.equal(cookieDiagnostics.cookiesFound, 1);
  assert.equal(cookieDiagnostics.droppedOversize, true);
  assert.equal(cookieDiagnostics.attached, false);
  assert.equal(cookieDiagnostics.cookieBytes, 0);
});

test("diagnostics never expose cookie names or values", async () => {
  const browser = browserStub({
    granted: true,
    cookies: [
      { name: "VISITOR_INFO1_LIVE", value: "super-secret-value", path: "/" },
      { name: "partitioned", value: "also-secret", path: "/", partitionKey: {} },
    ],
    authorizedOrigins: ["https://www.youtube.com"],
  });

  const { cookieDiagnostics } = await buildRequestContext(
    {
      url: "https://googlevideo.com/videoplayback",
      referrer: "https://www.youtube.com/watch?v=abc",
    },
    browser,
  );

  const serialized = JSON.stringify(cookieDiagnostics);
  assert.equal(serialized.includes("VISITOR_INFO1_LIVE"), false);
  assert.equal(serialized.includes("super-secret-value"), false);
  assert.equal(serialized.includes("also-secret"), false);
});

test("partitioned cookies and unsafe cookie names are excluded", () => {
  assert.equal(
    serializeUnpartitionedCookies([
      { name: "safe", value: "one", path: "/" },
      { name: "bad;name", value: "two", path: "/" },
      { name: "partitioned", value: "three", path: "/", partitionKey: {} },
    ]),
    "safe=one",
  );
  assert.equal(originPermissionPattern("blob:https://example.com/id"), null);
});
