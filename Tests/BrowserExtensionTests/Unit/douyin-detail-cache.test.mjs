import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const source = await readFile(
  new URL("../../../BrowserExtension/chrome/src/shared/douyin-detail-cache.js", import.meta.url),
  "utf8",
);

function makeContext() {
  const context = vm.createContext({ URL, Date, Math, JSON });
  context.globalThis = context;
  vm.runInContext(source, context);
  return context;
}

const SAMPLE = {
  awemeId: "7666722505813527848",
  desc: " 完整版《犯罪都市》以暴制暴天花板 #犯罪都市 ",
  duration: 199.4,
  urls: [
    { url: "https://v26-web.douyinvod.com/video/tos/a.mp4?signature=a", size: 504938148 },
    { url: "https://v95-web-sz.douyinvod.com/video/tos/b.mp4?signature=b", size: 123 },
    { url: "javascript:alert(1)", size: 1 },
    null,
  ],
};

test("modal_id 匹配时合成详情候选（语义标题 + 直链 + 尺寸）", () => {
  const { MacIDMDouyinDetailCache: cache } = makeContext();
  const pageURL = "https://www.douyin.com/jingxuan?modal_id=7666722505813527848";
  cache.store(SAMPLE);
  const candidates = cache.associatedCandidates(pageURL);
  assert.equal(candidates.length, 1);
  assert.equal(candidates[0].url, SAMPLE.urls[0].url);
  assert.equal(candidates[0].mime, "video/mp4");
  assert.equal(candidates[0].size, 504938148);
  assert.equal(candidates[0].filenameHint, "完整版《犯罪都市》以暴制暴天花板 #犯罪都市.mp4");
  assert.equal(candidates[0].filenameHintSource, "titleDerived");
  assert.equal(candidates[0].duration, 199.4);
  // 有界关联：归属 URL 集合用于 FAB scope
  assert.deepEqual(
    Array.from(cache.associatedURLs(pageURL)),
    [SAMPLE.urls[0].url, SAMPLE.urls[1].url],
  );
});

test("非 douyin host、无 modal_id、aweme_id 不匹配时一律不关联", () => {
  const { MacIDMDouyinDetailCache: cache } = makeContext();
  cache.store(SAMPLE);
  assert.equal(cache.associatedCandidates("https://www.example.com/jingxuan?modal_id=7666722505813527848").length, 0);
  assert.equal(cache.associatedCandidates("https://www.douyin.com/jingxuan").length, 0);
  assert.equal(cache.associatedCandidates("https://www.douyin.com/jingxuan?modal_id=999").length, 0);
  assert.equal(cache.associatedURLs("https://www.douyin.com/jingxuan").length, 0);
});

test("TTL 过期后不再关联", () => {
  const context = makeContext();
  const { MacIDMDouyinDetailCache: cache } = context;
  cache.store(SAMPLE);
  const pageURL = "https://www.douyin.com/jingxuan?modal_id=7666722505813527848";
  assert.equal(cache.associatedCandidates(pageURL).length, 1);
  // 推进vm时钟超过 30 分钟 TTL
  const future = Date.now() + 31 * 60 * 1000;
  assert.equal(cache.associatedURLs(pageURL, future).length, 0);
  assert.equal(cache.associatedCandidates(pageURL, future).length, 0);
});

test("容量上限淘汰最旧条目", () => {
  const { MacIDMDouyinDetailCache: cache } = makeContext();
  for (let i = 0; i < 12; i += 1) {
    cache.store({ awemeId: `id-${i}`, desc: `t-${i}`, urls: [{ url: `https://v.douyinvod.com/${i}.mp4`, size: i }] });
  }
  // 12 条已满：再存一条应淘汰最旧的 id-0
  cache.store({ awemeId: "id-new", desc: "newest", urls: [{ url: "https://v.douyinvod.com/new.mp4", size: 1 }] });
  assert.equal(cache.get("id-0"), null);
  assert.ok(cache.get("id-new"));
  // id-0 的 modal 不再关联
  assert.equal(cache.associatedCandidates(`https://www.douyin.com/jingxuan?modal_id=id-0`).length, 0);
});

test("无有效直链的条目不入库；非法 URL 被剔除", () => {
  const { MacIDMDouyinDetailCache: cache } = makeContext();
  cache.store({ awemeId: "empty", desc: "x", urls: [] });
  assert.equal(cache.get("empty"), null);
  cache.store(SAMPLE);
  const candidates = cache.associatedCandidates(
    "https://www.douyin.com/jingxuan?modal_id=7666722505813527848");
  // javascript: URL 必须被剔除，只保留 https 直链
  assert.ok(candidates[0].url.startsWith("https://"));
});

test("feedCardCandidates 只对卡片文本含 aweme_id 的条目合成候选", () => {
  const { MacIDMDouyinDetailCache: cache } = makeContext();
  cache.store(SAMPLE);
  cache.store({ awemeId: "999-not-on-page", urls: [{ url: "https://v.douyinvod.com/x.mp4", size: 5 }] });
  const cardText = "视频标题文字 7666722505813527848 更多文字";
  const candidates = cache.feedCardCandidates((id) => cardText.includes(id));
  assert.equal(candidates.length, 1);
  assert.equal(candidates[0].url, SAMPLE.urls[0].url);
  assert.equal(candidates[0].filenameHintSource, "titleDerived");
  // 卡片文本匹配不到任何条目 → 空
  assert.equal(cache.feedCardCandidates((id) => `unrelated ${id}`.length > 1 && false).length, 0);
});

test("urlsForCardText 返回卡片命中的全部直链（FAB 归属证据）", () => {
  const { MacIDMDouyinDetailCache: cache } = makeContext();
  cache.store(SAMPLE);
  const urls = cache.urlsForCardText("标题 7666722505813527848 简介");
  assert.deepEqual(Array.from(urls).sort(), [SAMPLE.urls[0].url, SAMPLE.urls[1].url].sort());
  assert.equal(cache.urlsForCardText("无关文本").length, 0);
  assert.equal(cache.urlsForCardText("").length, 0);
});
