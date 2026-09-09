import assert from "node:assert/strict";
import test from "node:test";

import { ExplicitEnqueueClient } from "../../../BrowserExtension/chrome/src/background/explicit-enqueue.js";
import { ProtocolError } from "../../../BrowserExtension/chrome/src/shared/protocol.js";

test("explicit enqueue retries with unique requestIds without creating a Chrome download", async () => {
  const requests = [];
  const nativeClient = {
    async send(request) {
      requests.push(request);
      if (requests.length < 3) throw new ProtocolError("TEMPORARY", "temporary bridge failure", true);
      return {
        protocolVersion: 1,
        requestId: request.requestId,
        type: "download.accepted",
        status: "ok",
        payload: { taskId: "4B907DC4-8759-4EAF-9677-F72D82B60A2C" },
      };
    },
  };
  const client = new ExplicitEnqueueClient({
    nativeClient,
    profileIDProvider: async () => "profile-test",
    requestContextProvider: async () => ({
      cookie: "session=fixture-secret",
      referer: "https://example.com/watch",
    }),
  });

  const result = await client.enqueue({
    url: "https://example.com/media.mp4",
    referrer: "https://example.com/watch",
    tabId: 7,
    mime: "video/mp4",
    operationID: "media-1",
  });

  assert.equal(result.taskId, "4B907DC4-8759-4EAF-9677-F72D82B60A2C");
  assert.equal(requests.length, 3);
  assert.equal(requests[0].type, "download.enqueue");
  assert.equal(requests[0].idempotencyKey, "profile-test:explicit-media-1");
  assert.equal(requests[0].payload.requestContext.cookie, "session=fixture-secret");
  assert.equal(requests[0].payload.tabId, 7);
  assert.equal(requests[0].payload.mime, "video/mp4");
  // Each retry uses a unique idempotencyKey to prevent delayed responses
  // from matching the wrong pending entry.
  assert.equal(requests[1].idempotencyKey, "profile-test:explicit-media-1:r1");
  assert.equal(requests[2].idempotencyKey, "profile-test:explicit-media-1:r2");
  assert.equal(requests[1].payload.url, requests[0].payload.url);
  assert.equal(requests[2].payload.url, requests[0].payload.url);
  assert.equal("browserDownloadId" in requests[0].payload, false);
});

test("media inspection carries only a transient request context for HLS and DASH", async () => {
  const requests = [];
  const client = new ExplicitEnqueueClient({
    nativeClient: {
      async send(request) {
        requests.push(request);
        return {
          protocolVersion: 1,
          requestId: request.requestId,
          type: "media.inspected",
          status: "ok",
          payload: {
            mediaKind: request.payload.mediaKind,
            variants: [{ label: "720p", url: "https://example.com/v.m3u8" }],
          },
        };
      },
    },
    profileIDProvider: async () => "profile-test",
    requestContextProvider: async () => ({ cookie: "session=secret" }),
  });

  const result = await client.inspect({
    url: "https://example.com/master.m3u8?token=secret",
    referrer: "https://example.com/watch",
    tabId: 3,
    operationID: "inspect-1",
  });

  assert.equal(result.variants[0].label, "720p");
  assert.equal(requests.length, 1);
  assert.equal(requests[0].type, "media.inspect");
  assert.equal(requests[0].payload.mediaKind, "hls");
  assert.equal(requests[0].payload.requestContext.cookie, "session=secret");
  assert.equal(requests[0].payload.tabId, 3);

  await client.inspect({
    url: "https://example.com/manifest.mpd",
    mediaKind: "dash",
    operationID: "inspect-dash-1",
  });
  assert.equal(requests[1].payload.mediaKind, "dash");
});

test("explicit enqueue preserves the controlled DASH media kind", async () => {
  let request;
  const client = new ExplicitEnqueueClient({
    nativeClient: {
      async send(value) {
        request = value;
        return {
          protocolVersion: 1,
          requestId: value.requestId,
          type: "download.accepted",
          status: "ok",
          payload: { taskId: "0D7B7B74-4A7D-4A0E-9C2A-9D2B9A8C8A01" },
        };
      },
    },
    profileIDProvider: async () => "profile-test",
    requestContextProvider: async () => ({}),
  });

  await client.enqueue({
    url: "https://example.com/manifest.mpd",
    mediaKind: "dash",
    filenameHint: "manifest.mp4",
    operationID: "dash-1",
  });
  assert.equal(request.payload.mediaKind, "dash");
});

test("interactive media enqueue returns a confirmation request instead of a task", async () => {
  let request;
  const client = new ExplicitEnqueueClient({
    nativeClient: {
      async send(value) {
        request = value;
        return {
          protocolVersion: 1,
          requestId: value.requestId,
          type: "media.downloadRequested",
          status: "ok",
          payload: { filenameHint: "课程标题.mp4" },
        };
      },
    },
    profileIDProvider: async () => "profile-test",
    requestContextProvider: async () => ({}),
  });

  const result = await client.enqueue({
    url: "https://example.com/video.mp4",
    filenameHint: "课程标题.mp4",
    pageTitle: "课程标题",
    interactive: true,
    operationID: "interactive-1",
  });

  assert.equal(result.filenameHint, "课程标题.mp4");
  assert.equal(request.type, "download.enqueue");
  assert.equal(request.payload.interactive, true);
  assert.equal(request.payload.pageTitle, "课程标题");
});

// Generic protocol failures are rewritten to the same user-facing message;
// the scenarios are isomorphic except for the error code and original detail.
for (const scenario of [
  {
    code: "APP_REJECTED",
    detail: "MacIDM 拒绝了本次接管，Chrome 下载将继续。",
    url: "https://example.com/master.m3u8",
    mediaKind: "hls",
    operationID: "inspect-fail-1",
  },
  {
    code: "INVALID_MESSAGE",
    detail: "MacIDM 接管失败（INVALID_MESSAGE）",
    url: "https://example.com/manifest.mpd",
    mediaKind: "dash",
    operationID: "inspect-fail-2",
  },
]) {
  test(`media inspection rewrites ${scenario.code} with a clearer message`, async () => {
    const client = new ExplicitEnqueueClient({
      nativeClient: {
        async send() {
          // Simulate validateResponse throwing for the scenario error.
          throw new ProtocolError(scenario.code, scenario.detail, false);
        },
      },
      profileIDProvider: async () => "profile-test",
      requestContextProvider: async () => ({}),
    });

    await assert.rejects(
      client.inspect({
        url: scenario.url,
        mediaKind: scenario.mediaKind,
        operationID: scenario.operationID,
      }),
      (error) => {
        assert.equal(error.code, scenario.code);
        assert.equal(error.message, "无法解析媒体画质，请稍后重试。");
        return true;
      },
    );
  });
}

test("media inspection preserves non-generic error messages", async () => {
  const client = new ExplicitEnqueueClient({
    nativeClient: {
      async send() {
        // A specific error like MEDIA_INVALID should be preserved.
        throw new ProtocolError(
          "MEDIA_INVALID",
          "无法解析当前媒体播放列表。",
          false,
        );
      },
    },
    profileIDProvider: async () => "profile-test",
    requestContextProvider: async () => ({}),
  });

  await assert.rejects(
    client.inspect({
      url: "https://example.com/master.m3u8",
      mediaKind: "hls",
      operationID: "inspect-fail-3",
    }),
    (error) => {
      assert.equal(error.code, "MEDIA_INVALID");
      assert.equal(error.message, "无法解析当前媒体播放列表。");
      return true;
    },
  );
});
