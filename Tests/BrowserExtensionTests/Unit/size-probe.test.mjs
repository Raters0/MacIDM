import assert from "node:assert/strict";
import test from "node:test";

import {
  cachedProbe,
  isProbeableCandidate,
  probeResourceSize,
} from "../../../BrowserExtension/chrome/src/background/size-probe.js";

test("direct http media without size is probeable", () => {
  assert.equal(
    isProbeableCandidate({ url: "https://cdn.example.com/video.mp4", format: "video" }),
    true,
  );
  assert.equal(
    isProbeableCandidate({ url: "http://cdn.example.com/audio.m4a", format: "audio" }),
    true,
  );
});

test("candidates that already carry a size are not probed again", () => {
  assert.equal(
    isProbeableCandidate({ url: "https://cdn.example.com/video.mp4", size: 1024 }),
    false,
  );
});

test("streaming manifests and site adapters are never probed", () => {
  assert.equal(
    isProbeableCandidate({ url: "https://example.com/index.m3u8", format: "hls" }),
    false,
  );
  assert.equal(
    isProbeableCandidate({ url: "https://example.com/manifest.mpd", format: "dash" }),
    false,
  );
  assert.equal(
    isProbeableCandidate({
      url: "https://www.youtube.com/watch?v=abc",
      siteAdapter: "youtube",
    }),
    false,
  );
  assert.equal(
    isProbeableCandidate({
      url: "https://www.bilibili.com/video/BV1",
      siteAdapter: "bilibili",
    }),
    false,
  );
});

test("internal fragments and non-http URLs are skipped", () => {
  assert.equal(
    isProbeableCandidate({ url: "https://cdn.example.com/seg.m4s", pairKind: "m4s-fragment" }),
    false,
  );
  assert.equal(
    isProbeableCandidate({ url: "https://cdn.example.com/seg.ts", pairKind: "stream-segment" }),
    false,
  );
  assert.equal(isProbeableCandidate({ url: "blob:https://example.com/uuid" }), false);
  assert.equal(isProbeableCandidate(null), false);
  assert.equal(isProbeableCandidate({}), false);
});

test("automatic probes are anonymous and never follow redirects", async () => {
  // A probe is not a user action. Carrying cookies or following redirects would
  // let a page turn the extension into a credentialed cross-site client.
  const calls = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    calls.push({ url, init });
    return new Response(null, {
      status: 200,
      headers: { "content-length": "4096", "content-type": "video/mp4" },
    });
  };
  try {
    const url = `https://cdn.example.com/anon-${Date.now()}.mp4`;
    const result = await probeResourceSize(url, { referer: "https://player.example.com/watch" });
    assert.ok(calls.length >= 1, "no probe request was issued");
    for (const call of calls) {
      assert.equal(call.init.credentials, "omit", "probe carried credentials");
      assert.equal(call.init.redirect, "error", "probe followed redirects");
    }
    assert.deepEqual(result, { size: 4096, mime: "video/mp4", cdFilename: null });
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("a redirecting target settles as unknown instead of following", async () => {
  const calls = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    calls.push(init);
    // Chrome rejects with opaqueredirect when redirect: "error" meets a 3xx.
    throw new TypeError("Failed to fetch");
  };
  try {
    const url = `https://cdn.example.com/redir-${Date.now()}.mp4`;
    const result = await probeResourceSize(url);
    assert.equal(result, null);
    assert.equal(calls.length, 2, "expected the HEAD attempt and the ranged fallback only");
    for (const init of calls) {
      assert.equal(init.credentials, "omit");
      assert.equal(init.redirect, "error");
    }
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("Content-Disposition filename is captured as the server-authoritative name", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => new Response(null, {
    status: 200,
    headers: {
      "content-length": "2048",
      "content-type": "video/mp4",
      "content-disposition": "attachment; filename*=UTF-8''%E8%A7%86%E9%A2%91.mp4",
    },
  });
  try {
    const url = `https://cdn.example.com/cd-${Date.now()}.mp4`;
    const result = await probeResourceSize(url);
    assert.equal(result.cdFilename, "视频.mp4");
    assert.equal(cachedProbe(url).cdFilename, "视频.mp4");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("a probed size is served from the cache without another request", async () => {
  // The service allows re-probing the same URL after the page re-reports it
  // (navigation drops the cache along with the size); the precondition for
  // this test making no network request is the cache hit below.
  const calls = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    calls.push(init.method);
    return new Response(null, {
      status: 200,
      headers: { "content-length": "123456", "content-type": "video/mp4" },
    });
  };
  try {
    const url = `https://cdn.example.com/cached-${Date.now()}.mp4`;
    const first = await probeResourceSize(url);
    const second = await probeResourceSize(url);
    assert.deepEqual(first, { size: 123456, mime: "video/mp4", cdFilename: null });
    assert.deepEqual(second, first);
    assert.deepEqual(calls, ["HEAD"], "第二次取值仍然发出了请求");
    assert.deepEqual(cachedProbe(url), { size: 123456, mime: "video/mp4", cdFilename: null });
  } finally {
    globalThis.fetch = originalFetch;
  }
});
