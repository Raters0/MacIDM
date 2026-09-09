import assert from "node:assert/strict";
import test from "node:test";

import {
  AUTHORIZED_ORIGINS_KEY,
} from "../../../BrowserExtension/chrome/src/shared/cookie-authorization.js";
import {
  authorizeSiteCookies,
  isHttpOrigin,
  permissionRequestFor,
} from "../../../BrowserExtension/chrome/src/authorize/authorize.js";

function storageStub() {
  const data = {};
  return {
    data,
    local: {
      async get(key) {
        return key in data ? { [key]: data[key] } : {};
      },
      async set(patch) {
        Object.assign(data, patch);
      },
    },
  };
}

test("permissionRequestFor scopes the cookies permission to the exact site origin", () => {
  assert.deepEqual(permissionRequestFor("https://www.bilibili.com"), {
    permissions: ["cookies"],
    origins: ["https://www.bilibili.com/*"],
  });
});

test("isHttpOrigin accepts http/https origins and rejects everything else", () => {
  assert.equal(isHttpOrigin("https://www.bilibili.com"), true);
  assert.equal(isHttpOrigin("http://example.com"), true);
  assert.equal(isHttpOrigin("ftp://example.com"), false);
  assert.equal(isHttpOrigin("chrome-extension://abc/page.html"), false);
  assert.equal(isHttpOrigin(""), false);
  assert.equal(isHttpOrigin("not a url"), false);
});

test("authorizeSiteCookies requests the origin scope and reports authorize.done", async () => {
  const requests = [];
  const messages = [];
  const storage = storageStub();
  const result = await authorizeSiteCookies({
    origin: "https://www.bilibili.com",
    tabId: 42,
    permissions: {
      async request(query) {
        requests.push(query);
        return true;
      },
    },
    runtime: {
      async sendMessage(message) {
        messages.push(message);
        return { ok: true };
      },
    },
    storage,
  });

  assert.equal(result.granted, true);
  assert.equal(result.reason, null);
  assert.deepEqual(requests, [{
    permissions: ["cookies"],
    origins: ["https://www.bilibili.com/*"],
  }]);
  // The service worker relies on this to close the window and re-parse the tab.
  assert.deepEqual(messages, [{ type: "authorize.done", granted: true, tabId: 42 }]);
  // Grant success must record the origin in the site-authorization ledger.
  assert.equal(storage.data["authorizedOrigin:https://www.bilibili.com"], true);
});

test("authorizeSiteCookies does not touch the ledger on a denial", async () => {
  const storage = storageStub();
  const result = await authorizeSiteCookies({
    origin: "https://www.bilibili.com",
    tabId: 7,
    permissions: { async request() { return false; } },
    runtime: { async sendMessage() {} },
    storage,
  });

  assert.equal(result.granted, false);
  assert.equal(storage.data[AUTHORIZED_ORIGINS_KEY], undefined);
});

test("authorizeSiteCookies reports a denial without throwing", async () => {
  const messages = [];
  const result = await authorizeSiteCookies({
    origin: "https://www.bilibili.com",
    tabId: 7,
    permissions: { async request() { return false; } },
    runtime: { async sendMessage(message) { messages.push(message); } },
  });

  assert.equal(result.granted, false);
  assert.equal(result.reason, "denied");
  assert.deepEqual(messages, [{ type: "authorize.done", granted: false, tabId: 7 }]);
});

test("authorizeSiteCookies refuses a non-http origin without requesting", async () => {
  let requested = false;
  const result = await authorizeSiteCookies({
    origin: "ftp://example.com",
    tabId: 1,
    permissions: { async request() { requested = true; return true; } },
    runtime: { async sendMessage() {} },
  });

  assert.equal(requested, false);
  assert.equal(result.granted, false);
  assert.equal(result.reason, "invalidOrigin");
});

test("authorizeSiteCookies surfaces a request failure as requestFailed", async () => {
  const result = await authorizeSiteCookies({
    origin: "https://www.bilibili.com",
    tabId: 1,
    permissions: {
      async request() {
        throw new Error("gesture required");
      },
    },
    runtime: { async sendMessage() {} },
  });

  assert.equal(result.granted, false);
  assert.equal(result.reason, "requestFailed");
});

test("authorizeSiteCookies tolerates a missing tabId and an evicted service worker", async () => {
  const result = await authorizeSiteCookies({
    origin: "https://www.bilibili.com",
    tabId: null,
    permissions: { async request() { return true; } },
    runtime: {
      async sendMessage() {
        throw new Error("Receiving end does not exist");
      },
    },
  });

  // A lost notification must not turn a granted permission into a failure.
  assert.equal(result.granted, true);
  assert.equal(result.reason, null);
});

test("ledger write failure never reports a successful authorization", async () => {
  const messages = [];
  const result = await authorizeSiteCookies({ origin: "https://example.com", tabId: 42,
    permissions: { request: async () => true }, runtime: { sendMessage: async message => messages.push(message) },
    storage: { local: { get: async () => ({}), set: async () => { throw new Error("disk failure"); } } },
  });
  assert.equal(result.granted, false);
  assert.equal(result.reason, "requestFailed");
  assert.equal(messages.some(message => message.granted), false);
});
