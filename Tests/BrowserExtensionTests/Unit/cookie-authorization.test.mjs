import assert from "node:assert/strict";
import test from "node:test";

import {
  AUTHORIZED_ORIGINS_KEY,
  addAuthorizedOrigin,
  isOriginAuthorized,
  normalizeHttpOrigin,
  readAuthorizedOrigins,
} from "../../../BrowserExtension/chrome/src/shared/cookie-authorization.js";

function storageStub(initial = {}) {
  const data = { ...initial };
  return {
    data,
    local: {
      async get(key) {
        return structuredClone(key == null ? data : key in data ? { [key]: data[key] } : {});
      },
      async set(patch) {
        Object.assign(data, patch);
      },
    },
  };
}

function browserStub({ storage, cookiesPermission = true } = {}) {
  return {
    permissions: {
      async contains(request) {
        // The only legitimate query shape left: extension-scoped API check.
        assert.deepEqual(request, { permissions: ["cookies"] });
        return cookiesPermission;
      },
    },
    storage,
  };
}

test("normalizeHttpOrigin keeps http/https origins and rejects everything else", () => {
  assert.equal(normalizeHttpOrigin("https://www.bilibili.com/video/BV1"), "https://www.bilibili.com");
  assert.equal(normalizeHttpOrigin("http://example.com:8080/a"), "http://example.com:8080");
  assert.equal(normalizeHttpOrigin("ftp://example.com"), null);
  assert.equal(normalizeHttpOrigin("chrome-extension://abc/page.html"), null);
  assert.equal(normalizeHttpOrigin(""), null);
  assert.equal(normalizeHttpOrigin("not a url"), null);
  assert.equal(normalizeHttpOrigin(null), null);
});

test("addAuthorizedOrigin records the origin once and ignores non-http values", async () => {
  const storage = storageStub();
  assert.equal(await addAuthorizedOrigin(storage, "https://www.bilibili.com/video"), true);
  assert.equal(await addAuthorizedOrigin(storage, "https://www.bilibili.com/other"), true);
  assert.deepEqual(await readAuthorizedOrigins(storage), ["https://www.bilibili.com"]);
  // Non-http origins never enter the ledger.
  assert.equal(await addAuthorizedOrigin(storage, "ftp://example.com"), false);
  assert.deepEqual(await readAuthorizedOrigins(storage), ["https://www.bilibili.com"]);
});

test("readAuthorizedOrigins tolerates missing, malformed, and failing storage", async () => {
  assert.deepEqual(await readAuthorizedOrigins(storageStub()), []);
  assert.deepEqual(
    await readAuthorizedOrigins(storageStub({ [AUTHORIZED_ORIGINS_KEY]: ["ok", 42, null] })),
    ["ok"],
  );
  const broken = {
    local: {
      async get() {
        throw new Error("storage unavailable");
      },
      async set() {},
    },
  };
  assert.deepEqual(await readAuthorizedOrigins(broken), []);
});

test("isOriginAuthorized requires both the ledger entry and the cookies permission", async () => {
  const storage = storageStub({ [AUTHORIZED_ORIGINS_KEY]: ["https://www.bilibili.com"] });

  // Ledger hit + permission granted → authorized.
  assert.equal(
    await isOriginAuthorized(browserStub({ storage }), "https://www.bilibili.com/video"),
    true,
  );

  // Origin absent from the ledger → not authorized, even though the cookies
  // permission is extension-granted. This is the regression guard for the
  // permissions.contains bug that reported every site as authorized.
  assert.equal(
    await isOriginAuthorized(browserStub({ storage }), "https://example.com/watch"),
    false,
  );

  // Permission revoked at chrome://extensions → ledger entry becomes inert.
  assert.equal(
    await isOriginAuthorized(browserStub({ storage, cookiesPermission: false }), "https://www.bilibili.com"),
    false,
  );

  // Ledger write happened but permissions.contains throws → fail closed.
  const throwing = {
    permissions: {
      async contains() {
        throw new Error("permissions unavailable");
      },
    },
    storage,
  };
  assert.equal(await isOriginAuthorized(throwing, "https://www.bilibili.com"), false);
});

 test("concurrent windows retain both authorizations", async () => {
  const data = {};
  const storage = { local: {
    async get(key) { return structuredClone(key == null ? data : { [key]: data[key] }); },
    async set(patch) { Object.assign(data, structuredClone(patch)); },
  }};
  await Promise.all([addAuthorizedOrigin(storage, "https://a.example"), addAuthorizedOrigin(storage, "https://b.example")]);
  assert.equal(await isOriginAuthorized(browserStub({ storage }), "https://a.example"), true);
  assert.equal(await isOriginAuthorized(browserStub({ storage }), "https://b.example"), true);
});
