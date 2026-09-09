import assert from "node:assert/strict";
import test from "node:test";

import {
  rememberBackgroundCandidate,
  takeBackgroundCandidates,
} from "../../../BrowserExtension/chrome/src/background/media-observation.js";

test("background media observations are released to the matching page origin", () => {
  const buckets = new Map();
  assert.equal(
    rememberBackgroundCandidate(
      buckets,
      "https://www.example.com/watch",
      { url: "https://cdn.example.com/video.m4s", format: "video" },
      1_000,
    ),
    true,
  );

  assert.deepEqual(
    takeBackgroundCandidates(buckets, "https://www.example.com/other", 1_500),
    [{ url: "https://cdn.example.com/video.m4s", format: "video" }],
  );
  assert.deepEqual(takeBackgroundCandidates(buckets, "https://other.example.com/", 1_500), []);
  assert.deepEqual(takeBackgroundCandidates(buckets, "https://www.example.com/", 121_001), []);
});

test("background observations enforce a bounded per-origin cache", () => {
  const buckets = new Map();
  for (let index = 0; index < 3; index += 1) {
    rememberBackgroundCandidate(
      buckets,
      "https://example.com/watch",
      { url: `https://cdn.example.com/${index}.mp4` },
      2_000 + index,
      10_000,
      2,
    );
  }
  assert.deepEqual(
    takeBackgroundCandidates(buckets, "https://example.com/watch", 2_100)
      .map((candidate) => candidate.url),
    ["https://cdn.example.com/1.mp4", "https://cdn.example.com/2.mp4"],
  );
});

test("invalid initiators and non-http pages are ignored", () => {
  const buckets = new Map();
  assert.equal(rememberBackgroundCandidate(buckets, "null", { url: "https://cdn.example/a.mp4" }), false);
  assert.equal(rememberBackgroundCandidate(buckets, "file:///tmp/page", { url: "https://cdn.example/a.mp4" }), false);
  assert.deepEqual(takeBackgroundCandidates(buckets, "file:///tmp/page"), []);
});

test("mergeTabMediaCache: YouTube A→B 换代时清空旧标题，即使传入 A 的 tab title 也被 content main-frame 空快照重置", async () => {
  const { mergeTabMediaCache } = await import("../../../BrowserExtension/chrome/src/background/media-observation.js");
  const URL_A = "https://www.youtube.com/watch?v=videoA11111";
  const URL_B = "https://www.youtube.com/watch?v=videoB22222";

    // 1. The tab originally sits on video A with a fully confirmed title
    const stateA = mergeTabMediaCache(null, {
      pageUrl: URL_A,
      title: "Title for Video A",
      candidates: [{ url: URL_A, siteAdapter: "youtube" }],
    }, 0);
    assert.equal(stateA.title, "Title for Video A");

    // 2. A→B navigation happens: the background observation first receives
    // URL_B plus the lagging tab.title (still video A's title)
    const stateB1 = mergeTabMediaCache(stateA, {
      pageUrl: URL_B,
      title: "Title for Video A",
      candidates: [{ url: URL_B, siteAdapter: "youtube" }],
    }, 0);

    // 3. The content-script main-frame snapshot arrives (title is empty
    // because video B's player has not confirmed a title yet)
    const stateB2 = mergeTabMediaCache(stateB1, {
      pageUrl: URL_B,
      title: "",
      candidates: [{ url: URL_B, siteAdapter: "youtube" }],
    }, 0);
    assert.equal(stateB2.title, "", "A→B 换代后权威快照 title 为空时，输出标题必须为空，绝不回退视频 A 标题");

    // 4. Video B's player is ready and the confirmed title arrives
    const stateB3 = mergeTabMediaCache(stateB2, {
      pageUrl: URL_B,
      title: "Title for Video B",
      candidates: [{ url: URL_B, siteAdapter: "youtube" }],
    }, 0);
    assert.equal(stateB3.title, "Title for Video B", "视频 B 确认标题到达后正常更新");

    // 5. Same videoId with only a URL parameter change (&t=60s): the
    // confirmed title is kept when the content script sends an empty title
    const stateB4 = mergeTabMediaCache(stateB3, {
      pageUrl: `${URL_B}&t=60s`,
      title: "",
      candidates: [{ url: `${URL_B}&t=60s`, siteAdapter: "youtube" }],
    }, 0);
    assert.equal(stateB4.title, "Title for Video B", "同 videoId 参数变化保留已确认标题");

    // 6. Same videoId with only a fragment change (#t=90s): keep the
    // confirmed title
    const stateB5 = mergeTabMediaCache(stateB4, {
      pageUrl: `${URL_B}#t=90s`,
      title: "",
      candidates: [{ url: `${URL_B}#t=90s`, siteAdapter: "youtube" }],
    }, 0);
    assert.equal(stateB5.title, "Title for Video B", "同 videoId fragment 变化保留已确认标题");

    // 7. Navigating again to video C: the old title is cleared
    const URL_C = "https://www.youtube.com/watch?v=videoC33333";
    const stateC = mergeTabMediaCache(stateB5, {
      pageUrl: URL_C,
      title: "",
      candidates: [{ url: URL_C, siteAdapter: "youtube" }],
    }, 0);
    assert.equal(stateC.title, "", "换到视频 C 且标题未确认时清空旧标题");
});

test("mergeTabMediaCache: 非 YouTube 页面 exact URL 语义与 iframe 隔离", async () => {
  const { mergeTabMediaCache } = await import("../../../BrowserExtension/chrome/src/background/media-observation.js");
  const PAGE_1 = "https://example.com/article/1";
  const PAGE_2 = "https://example.com/article/2";

  // 1. Page 1 initial load
  const state1 = mergeTabMediaCache(null, {
    pageUrl: PAGE_1,
    title: "Article 1 Title",
    candidates: [{ url: "https://example.com/video1.mp4", format: "video" }],
  }, 0);
  assert.equal(state1.title, "Article 1 Title");

  // 2. An iframe inside page 1 reports candidates without a title: the
  // main-frame title is untouched
  const state1Iframe = mergeTabMediaCache(state1, {
    pageUrl: "https://ad.example.com/frame",
    title: "Ad Title",
    candidates: [{ url: "https://ad.example.com/ad.mp4", format: "video" }],
  }, 1);
  assert.equal(state1Iframe.title, "Article 1 Title", "iframe 上报不改写主帧标题");
  assert.equal(state1Iframe.pageUrl, PAGE_1, "iframe 上报不改写主帧 pageUrl");

  // 3. Page 1 reloads with a temporarily empty title: exact same page keeps
  // the confirmed title
  const state1Refresh = mergeTabMediaCache(state1Iframe, {
    pageUrl: PAGE_1,
    title: "",
    candidates: [{ url: "https://example.com/video1.mp4", format: "video" }],
  }, 0);
  assert.equal(state1Refresh.title, "Article 1 Title", "同 URL 刷新且 title 为空时保持既有标题");

  // 4. Navigating to page 2 with an empty title: page 1's title is not
  // inherited
  const state2Empty = mergeTabMediaCache(state1Refresh, {
    pageUrl: PAGE_2,
    title: "",
    candidates: [{ url: "https://example.com/video2.mp4", format: "video" }],
  }, 0);
  assert.equal(state2Empty.title, "", "换 URL 且 title 为空时不继承旧页面标题");

  // 5. Page 2's title arrives
  const state2Confirmed = mergeTabMediaCache(state2Empty, {
    pageUrl: PAGE_2,
    title: "Article 2 Title",
    candidates: [{ url: "https://example.com/video2.mp4", format: "video" }],
  }, 0);
  assert.equal(state2Confirmed.title, "Article 2 Title", "新页面标题到达后正常更新");
});

test("mergeTabMediaCache: background 发生 A→B 换代时输出 title 为空，不会受 A tabs title 污染", async () => {
  const { mergeTabMediaCache } = await import("../../../BrowserExtension/chrome/src/background/media-observation.js");
  const URL_A = "https://www.youtube.com/watch?v=meiVideoA";
  const URL_B = "https://www.youtube.com/watch?v=zenVideoB";

  // The background cache holds the old video A state
  const bgStateA = mergeTabMediaCache(null, {
    pageUrl: URL_A,
    title: "What 4300+ Hours of MEI Looks Like",
    candidates: [{ url: URL_A, siteAdapter: "youtube" }],
  }, 0);

  // The user navigated the page to video B, but tab.title is still A's old
  // title; getPopupMediaCandidates in the background processes the network
  // candidate observation (title forced empty for YouTube) and merges the
  // main-frame snapshot
  const bgStateB1 = mergeTabMediaCache(bgStateA, {
    pageUrl: URL_B,
    title: "", // no tab.title injected for YouTube at the background observation stage
    candidates: [{ url: URL_B, siteAdapter: "youtube", filenameHint: "YouTube 视频.mp4" }],
  }, 0);

  assert.equal(bgStateB1.title, "", "Background 输出的 title 必须为空");
});

test("alignMediaTabStateWithLiveURL: 最终返回守卫直接拦截跨视频旧缓存（live B + cached A）", async () => {
  const { alignMediaTabStateWithLiveURL } = await import("../../../BrowserExtension/chrome/src/background/media-observation.js");
  const URL_A = "https://www.youtube.com/watch?v=J-Rqrew32mw";
  const URL_B = "https://www.youtube.com/watch?v=eaPs5BmolTI";

  // 1. Simulated race: the content script has not updated or failed, and the
  // cache still holds entirely video A's data (full title, 18 variants, size)
  const cachedA = {
    pageUrl: URL_A,
    title: "What 4300+ Hours of MEI Looks Like - Overwatch 2",
    candidates: [
      {
        url: URL_A,
        siteAdapter: "youtube",
        filenameHint: "What 4300+ Hours of MEI Looks Like - Overwatch 2.mp4",
        size: 165675008,
        variants: [{ label: "1080P", url: `${URL_A}#1080` }],
      },
    ],
    filteredSummary: { diagnosticAudio: 0, streamSegments: 0 },
  };

  // 2. The live URL is already video B: the guard must intercept old video A
  // and output a clean initial adapter candidate for B
  const alignedB = alignMediaTabStateWithLiveURL(cachedA, URL_B);
  assert.equal(alignedB.ok, true);
  assert.equal(alignedB.pageUrl, URL_B, "最终返回的 pageUrl 必须为实时视频 B");
  assert.equal(alignedB.title, "", "最终返回的 title 必须为空，绝不得包含视频 A 标题");
  assert.equal(alignedB.candidates.length, 1);
  assert.equal(alignedB.candidates[0].url, URL_B, "候选 URL 必须为视频 B");
  assert.equal(alignedB.candidates[0].filenameHint, "YouTube 视频.mp4");
  assert.equal(alignedB.candidates[0].displayName, "YouTube 视频");
  assert.equal(alignedB.candidates[0].variants, undefined, "绝不得泄露视频 A 的变体列表");
  assert.equal(alignedB.candidates[0].size, null, "绝不得泄露视频 A 的估算大小");
});

test("alignMediaTabStateWithLiveURL: buildSafeYouTubeCandidate 支持 en/zh-CN 本地化", async () => {
  const { buildSafeYouTubeCandidate } = await import("../../../BrowserExtension/chrome/src/background/media-observation.js");
  const { i18n } = await import("../../../BrowserExtension/chrome/src/shared/i18n-access.js");
  const URL_B = "https://www.youtube.com/watch?v=eaPs5BmolTI";

  // Default zh-CN
  const candZh = buildSafeYouTubeCandidate(URL_B);
  assert.equal(candZh.displayName, "YouTube 视频");
  assert.equal(candZh.filenameHint, "YouTube 视频.mp4");

  // Switch to en
  i18n.setLanguage("en");
  try {
    const candEn = buildSafeYouTubeCandidate(URL_B);
    assert.equal(candEn.displayName, "YouTube video");
    assert.equal(candEn.filenameHint, "YouTube video.mp4");
  } finally {
    i18n.setLanguage("zh-CN");
  }
});

test("alignMediaTabStateWithLiveURL: 同一视频参数变化（live B&t + cached B）保留完整标题与画质", async () => {
  const { alignMediaTabStateWithLiveURL } = await import("../../../BrowserExtension/chrome/src/background/media-observation.js");
  const URL_B = "https://www.youtube.com/watch?v=eaPs5BmolTI";
  const URL_B_PARAM = `${URL_B}&t=60s`;

  // The cache already holds video B's confirmed data
  const cachedB = {
    pageUrl: URL_B,
    title: "Why Streamers HATE my Mei...",
    candidates: [
      {
        url: URL_B,
        siteAdapter: "youtube",
        filenameHint: "Why Streamers HATE my Mei....mp4",
        size: 165675008,
        variants: [{ label: "1080P", url: `${URL_B}#1080` }],
      },
    ],
    filteredSummary: { diagnosticAudio: 0, streamSegments: 0 },
  };

  const alignedBParam = alignMediaTabStateWithLiveURL(cachedB, URL_B_PARAM);
  assert.equal(alignedBParam.pageUrl, URL_B_PARAM, "pageUrl 对齐到实时 URL");
  assert.equal(alignedBParam.title, "Why Streamers HATE my Mei...", "保留已确认标题");
  assert.equal(alignedBParam.candidates.length, 1);
  assert.equal(alignedBParam.candidates[0].url, URL_B_PARAM, "候选 URL 对齐到实时 URL");
  assert.equal(alignedBParam.candidates[0].size, 165675008, "估算大小保留");
  assert.deepEqual(alignedBParam.candidates[0].variants, [{ label: "1080P", url: `${URL_B}#1080` }], "变体列表保留");
});

test("alignMediaTabStateWithLiveURL: 非 YouTube 页面跨 URL（live page2 + cached page1）清空旧状态", async () => {
  const { alignMediaTabStateWithLiveURL } = await import("../../../BrowserExtension/chrome/src/background/media-observation.js");
  const PAGE_1 = "https://example.com/article/1";
  const PAGE_2 = "https://example.com/article/2";

  const cached1 = {
    pageUrl: PAGE_1,
    title: "Article 1",
    candidates: [{ url: "https://example.com/video1.mp4", format: "video" }],
    filteredSummary: { diagnosticAudio: 0, streamSegments: 0 },
  };

  const aligned2 = alignMediaTabStateWithLiveURL(cached1, PAGE_2);
  assert.equal(aligned2.pageUrl, PAGE_2);
  assert.equal(aligned2.title, "", "非 YouTube 换 URL 后不得返回旧标题");
  assert.deepEqual(aligned2.candidates, [], "非 YouTube 换 URL 后不得返回旧候选");
});
