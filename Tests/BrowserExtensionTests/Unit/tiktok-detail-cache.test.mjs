import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const source = await readFile(
  new URL("../../../BrowserExtension/chrome/src/shared/tiktok-detail-cache.js", import.meta.url),
  "utf8",
);

function makeContext() {
  const context = vm.createContext({ URL, Date, Math, JSON });
  context.globalThis = context;
  vm.runInContext(source, context);
  return context;
}

const ITEM_ID = "7681925651783339286";
const DETAIL_PAGE = `https://www.tiktok.com/@someone/video/${ITEM_ID}`;

const SAMPLE = {
  itemId: ITEM_ID,
  desc: " 完整版《犯罪都市》以暴制暴天花板 #犯罪都市 ",
  duration: 77,
  urls: [
    { url: "https://v16-webapp-prime.tiktok.com/video/tos/no1a/gear1/?a=1988&mime_type=video_mp4", size: 9000000 },
    { url: "https://v16-webapp-prime.tiktok.com/video/tos/no1a/gear0/?a=1988&mime_type=video_mp4", size: 5450948 },
    { url: "javascript:alert(1)", size: 1 },
    null,
  ],
};

test("normalizeItemStruct 按码率降序提取直链并去重 playAddr", () => {
  const { MacIDMTikTokDetailCache: cache } = makeContext();
  const entry = cache.normalizeItemStruct({
    id: ITEM_ID,
    desc: " Simpeleellä asuva Pentti #suomi ",
    video: {
      duration: 77,
      playAddr: "https://v16-webapp-prime.tiktok.com/video/tos/no1a/gear0/?a=1988",
      bitrateInfo: [
        { Bitrate: 800000, GearName: "adapt_540_1", PlayAddr: { UrlList: ["https://v16-webapp-prime.tiktok.com/video/tos/no1a/gear0/?a=1988", "https://v16-webapp-prime.tiktok.com/video/tos/no1a/mirror/?a=1988"], DataSize: "5450948" } },
        { Bitrate: 1200000, GearName: "adapt_lower_720_1", PlayAddr: { UrlList: ["https://v16-webapp-prime.tiktok.com/video/tos/no1a/gear1/?a=1988"], DataSize: 9000000 } },
        { Bitrate: "bad", PlayAddr: { UrlList: ["javascript:alert(1)"] } },
      ],
    },
  });
  assert.equal(entry.itemId, ITEM_ID);
  assert.equal(entry.duration, 77);
  assert.deepEqual(Array.from(entry.urls, (item) => item.url), [
    "https://v16-webapp-prime.tiktok.com/video/tos/no1a/gear1/?a=1988",
    "https://v16-webapp-prime.tiktok.com/video/tos/no1a/gear0/?a=1988",
  ]);
  assert.equal(entry.urls[0].size, 9000000);
  assert.equal(entry.urls[1].size, 5450948);
});

test("normalizeItemStruct 容忍移动端 play_addr.url_list 形状并拒绝非法结构", () => {
  const { MacIDMTikTokDetailCache: cache } = makeContext();
  const entry = cache.normalizeItemStruct({
    id: ITEM_ID,
    video: {
      duration: 10,
      play_addr: { url_list: ["https://v16-webapp.tiktok.com/video/tos/a/?mime_type=video_mp4"], data_size: 1000 },
    },
  });
  assert.deepEqual(Array.from(entry.urls, (item) => item.url), ["https://v16-webapp.tiktok.com/video/tos/a/?mime_type=video_mp4"]);
  assert.equal(entry.urls[0].size, 1000);
  // 缺 id / id 非数字 / 无 video / 无直链一律 null。
  assert.equal(cache.normalizeItemStruct(null), null);
  assert.equal(cache.normalizeItemStruct({ id: "abc", video: { playAddr: "https://x/a.mp4" } }), null);
  assert.equal(cache.normalizeItemStruct({ id: ITEM_ID }), null);
  assert.equal(cache.normalizeItemStruct({ id: ITEM_ID, video: { playAddr: "javascript:alert(1)" } }), null);
});

test("详情页 /video/<id> 匹配时合成候选（语义标题 + 直链 + 尺寸）", () => {
  const { MacIDMTikTokDetailCache: cache } = makeContext();
  cache.store(SAMPLE);
  const candidates = cache.associatedCandidates(DETAIL_PAGE);
  assert.equal(candidates.length, 1);
  assert.equal(candidates[0].url, SAMPLE.urls[0].url);
  assert.equal(candidates[0].mime, "video/mp4");
  assert.equal(candidates[0].format, "video");
  assert.equal(candidates[0].fileExtension, "mp4");
  assert.equal(candidates[0].size, 9000000);
  assert.equal(candidates[0].filenameHint, "完整版《犯罪都市》以暴制暴天花板 #犯罪都市.mp4");
  assert.equal(candidates[0].filenameHintSource, "titleDerived");
  assert.equal(candidates[0].duration, 77);
  // 有界关联：归属 URL 集合用于 FAB scope。
  assert.deepEqual(
    Array.from(cache.associatedURLs(DETAIL_PAGE)),
    [SAMPLE.urls[0].url, SAMPLE.urls[1].url],
  );
});

test("modal_item_id 参数同样可关联；非 tiktok host、无 id、id 不匹配一律不关联", () => {
  const { MacIDMTikTokDetailCache: cache } = makeContext();
  cache.store(SAMPLE);
  assert.equal(
    cache.associatedCandidates(`https://www.tiktok.com/explore?modal_item_id=${ITEM_ID}`).length,
    1,
  );
  assert.equal(cache.associatedCandidates("https://www.example.com/video/7681925651783339286").length, 0);
  assert.equal(cache.associatedCandidates("https://www.tiktok.com/explore").length, 0);
  assert.equal(cache.associatedCandidates("https://www.tiktok.com/@someone/video/999").length, 0);
  assert.equal(cache.associatedURLs("https://www.tiktok.com/explore").length, 0);
});

test("TTL 过期后不再关联", () => {
  const { MacIDMTikTokDetailCache: cache } = makeContext();
  cache.store(SAMPLE);
  assert.equal(cache.associatedCandidates(DETAIL_PAGE).length, 1);
  const future = Date.now() + 31 * 60 * 1000;
  assert.equal(cache.associatedURLs(DETAIL_PAGE, future).length, 0);
  assert.equal(cache.associatedCandidates(DETAIL_PAGE, future).length, 0);
});

test("容量上限（48）淘汰最旧条目", () => {
  const { MacIDMTikTokDetailCache: cache } = makeContext();
  cache.store(SAMPLE);
  for (let i = 0; i < 48; i += 1) {
    cache.store({ itemId: `76810000000000000${String(i).padStart(2, "0")}`, desc: `t-${i}`, urls: [{ url: `https://v16-webapp-prime.tiktok.com/video/tos/no1a/${i}/?mime_type=video_mp4`, size: i }] });
  }
  assert.equal(cache.get(ITEM_ID), null);
  assert.ok(cache.get("7681000000000000047"));
  assert.equal(cache.associatedCandidates(DETAIL_PAGE).length, 0);
});

test("无有效直链的条目不入库；非法 URL 被剔除", () => {
  const { MacIDMTikTokDetailCache: cache } = makeContext();
  cache.store({ itemId: "empty", desc: "x", urls: [] });
  assert.equal(cache.get("empty"), null);
  cache.store(SAMPLE);
  const candidates = cache.associatedCandidates(DETAIL_PAGE);
  assert.ok(candidates[0].url.startsWith("https://"));
});

test("feedCardCandidates 只对卡片文本含 item_id 的条目合成候选", () => {
  const { MacIDMTikTokDetailCache: cache } = makeContext();
  cache.store(SAMPLE);
  cache.store({ itemId: "999-not-on-page", urls: [{ url: "https://v16-webapp-prime.tiktok.com/video/tos/no1a/x/?mime_type=video_mp4", size: 5 }] });
  const cardText = `视频标题文字 ${ITEM_ID} 更多文字`;
  const candidates = cache.feedCardCandidates((id) => cardText.includes(id));
  assert.equal(candidates.length, 1);
  assert.equal(candidates[0].url, SAMPLE.urls[0].url);
  assert.equal(candidates[0].filenameHintSource, "titleDerived");
  assert.equal(cache.feedCardCandidates(() => false).length, 0);
});

test("urlsForCardText 返回卡片命中的全部直链（FAB 归属证据）", () => {
  const { MacIDMTikTokDetailCache: cache } = makeContext();
  cache.store(SAMPLE);
  const urls = cache.urlsForCardText(`标题 ${ITEM_ID} 简介`);
  assert.deepEqual(Array.from(urls).sort(), [SAMPLE.urls[0].url, SAMPLE.urls[1].url].sort());
  assert.equal(cache.urlsForCardText("无关文本").length, 0);
  assert.equal(cache.urlsForCardText("").length, 0);
});

test("urlsForDescText 按 desc 归一化前缀匹配（详情 feed slide 归属证据）", () => {
  const { MacIDMTikTokDetailCache: cache } = makeContext();
  cache.store(SAMPLE);
  // desc 头 40 字符（归一化空白后）出现在 slide 文本中即命中全部直链。
  const slideText = `作者名 ${SAMPLE.desc.replace(/\s+/gu, " ").trim()} 话题标签`;
  assert.deepEqual(
    Array.from(cache.urlsForDescText(slideText)).sort(),
    [SAMPLE.urls[0].url, SAMPLE.urls[1].url].sort(),
  );
  // 文本过短、无关文本、空白差异均不误匹配。
  assert.equal(cache.urlsForDescText("太短").length, 0);
  assert.equal(cache.urlsForDescText("完全无关的 slide 文本，长度足够但不匹配任何条目").length, 0);
  const collapsed = cache.urlsForDescText(`作者名 ${SAMPLE.desc.replace(/\s+/gu, " ")} 更多`);
  assert.equal(collapsed.length, 2);
});

test("descForSlideText 返回命中条目的语义标题（卡片标题第一证据）", () => {
  const { MacIDMTikTokDetailCache: cache } = makeContext();
  cache.store(SAMPLE);
  const slideText = `作者名 ${SAMPLE.desc.replace(/\s+/gu, " ").trim()} 话题标签`;
  assert.equal(cache.descForSlideText(slideText), SAMPLE.desc.replace(/\s+/gu, " ").trim());
  assert.equal(cache.descForSlideText("完全无关的 slide 文本，长度足够但不匹配"), "");
  assert.equal(cache.descForSlideText("太短"), "");
  // 多条目并存时按插入序取第一个命中。
  cache.store({ itemId: "7681999999999999998", desc: "另一条完全不同的视频描述文本足够长", urls: [{ url: "https://v16-webapp-prime.tiktok.com/video/tos/other/?mime_type=video_mp4", size: 1 }] });
  assert.equal(cache.descForSlideText("开头无关 另一条完全不同的视频描述文本足够长 尾部"), "另一条完全不同的视频描述文本足够长");
});

test("slideCandidates 按 slide 文本合成候选并按 URL 去重", () => {
  const { MacIDMTikTokDetailCache: cache } = makeContext();
  cache.store(SAMPLE);
  cache.store({
    itemId: "7681999999999999998",
    desc: "另一条完全不同的视频描述文本足够长",
    duration: 21,
    urls: [{ url: "https://v16-webapp-prime.tiktok.com/video/tos/other/?mime_type=video_mp4", size: 42 }],
  });
  const descTexts = [
    `作者名 ${SAMPLE.desc.trim()} 标签`,
    "另一条完全不同的视频描述文本足够长",
    "太短",
    "完全无关的 slide 文本，长度足够但不匹配任何条目",
  ];
  const candidates = cache.slideCandidates(descTexts);
  assert.equal(candidates.length, 2);
  assert.deepEqual(
    Array.from(candidates, (c) => c.filenameHintSource),
    ["titleDerived", "titleDerived"],
  );
  // 同一 slide 文本重复出现不产生重复行。
  const duplicated = cache.slideCandidates([descTexts[0], descTexts[0]]);
  assert.equal(duplicated.length, 1);
  assert.equal(cache.slideCandidates([]).length, 0);
  assert.equal(cache.slideCandidates("not an array").length, 0);
});

test("videoIdOf 识别 /video/<id> 路径与 modal_item_id，拒绝非 tiktok host", () => {
  const { MacIDMTikTokDetailCache: cache } = makeContext();
  assert.equal(cache.videoIdOf(DETAIL_PAGE), ITEM_ID);
  assert.equal(cache.videoIdOf(`https://www.tiktok.com/explore?modal_item_id=${ITEM_ID}`), ITEM_ID);
  assert.equal(cache.videoIdOf("https://www.tiktok.com/explore"), null);
  assert.equal(cache.videoIdOf("https://evil.com/video/7681925651783339286"), null);
  assert.equal(cache.videoIdOf("not a url"), null);
});
