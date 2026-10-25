import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

// 命名可信度模型（技术规范 §8.1）：filenameHint 必须携带来源标注，
// 泛化占位词清单在扩展 JS 与 App Swift 两侧必须一致。

const read = (path) =>
  readFile(new URL(`../../../BrowserExtension/chrome/src/${path}`, import.meta.url), "utf8");
const source = await read("shared/media-utils.js");
const i18nSource = await read("shared/i18n.js");
const localeZhSource = await read("shared/locale-zh-cn.js");
const localeEnSource = await read("shared/locale-en.js");
// 占位名安全网按词条全串相等判定，所以必须与 youtube-preview-identity 一样
// 先装载 i18n 与两份词条：t() 回落到裸 key 时判定会整体失效。
const context = vm.createContext({ URL });
context.globalThis = context;
vm.runInContext(i18nSource, context);
vm.runInContext(localeZhSource, context);
vm.runInContext(localeEnSource, context);
vm.runInContext(source, context);
const mediaUtils = context.MacIDMMediaUtils;

test("filenameHintSourceFor marks synthesized names as titleDerived", () => {
  assert.equal(mediaUtils.filenameHintSourceFor({ siteAdapter: "youtube" }), "titleDerived");
  assert.equal(mediaUtils.filenameHintSourceFor({ siteAdapter: "bilibili" }), "titleDerived");
  assert.equal(mediaUtils.filenameHintSourceFor({ pairKind: "m4s-pair" }), "titleDerived");
  assert.equal(mediaUtils.filenameHintSourceFor({ pairKind: "stream-segment" }), "titleDerived");
  assert.equal(
    mediaUtils.filenameHintSourceFor({ url: "https://example.com/a.mp4", filenameHint: "a.mp4" }),
    "urlPath",
  );
  assert.equal(mediaUtils.filenameHintSourceFor(null), "urlPath");
  assert.equal(mediaUtils.filenameHintSourceFor(undefined), "urlPath");
});

test("a hint that fell back to the generic site label never claims titleDerived", () => {
  // 多视频列表页（如 B 站稍后再看）页级标题是品牌名，合成被置空后适配器行
  // 的 hint 落到泛化站点标签；该标签未由任何具体标题合成，不得在 App 命名
  // 链中压过面板已解析出的真实 pageTitle（技术规范 §8.1）。
  assert.equal(
    mediaUtils.filenameHintSourceFor({
      url: "https://www.bilibili.com/list/watchlater?bvid=BV1abcDEFghi&oid=12345",
      siteAdapter: "bilibili",
      filenameHint: "Bilibili 媒体.mp4",
    }),
    "urlPath",
  );
  assert.equal(
    mediaUtils.filenameHintSourceFor({
      url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
      siteAdapter: "youtube",
      filenameHint: "YouTube 视频.mp4",
    }),
    "urlPath",
  );
  // 显式声明的 titleDerived 同样受此守卫约束。
  assert.equal(
    mediaUtils.filenameHintSourceFor({
      url: "https://www.bilibili.com/list/watchlater?bvid=BV1abcDEFghi&oid=12345",
      siteAdapter: "bilibili",
      filenameHint: "Bilibili 媒体.mp4",
      filenameHintSource: "titleDerived",
    }),
    "urlPath",
  );
  // 真实标题合成的 hint 仍保留 titleDerived 信任。
  assert.equal(
    mediaUtils.filenameHintSourceFor({
      url: "https://www.bilibili.com/video/BV1abcDEFghi",
      siteAdapter: "bilibili",
      filenameHint: "某个具体视频标题.mp4",
    }),
    "titleDerived",
  );
  // 无 hint 的站点适配候选行为不变（标注不会上送线路）。
  assert.equal(mediaUtils.filenameHintSourceFor({ siteAdapter: "bilibili", url: "https://www.bilibili.com/video/BV1abcDEFghi" }), "titleDerived");
});

test("watch-later adapter synthesis with an empty page title yields an untrusted hint", () => {
  const watchlaterURL = "https://www.bilibili.com/list/watchlater?bvid=BV1abcDEFghi&oid=12345";
  const rows = mediaUtils.coalesceMediaCandidates([], "", watchlaterURL, []);
  const adapter = rows.find((candidate) => candidate?.siteAdapter === "bilibili");
  assert.ok(adapter, "空标题下仍必须合成页面适配器行");
  assert.equal(mediaUtils.filenameHintSourceFor(adapter), "urlPath");

  const namedRows = mediaUtils.coalesceMediaCandidates([], "某个具体视频标题", watchlaterURL, []);
  const namedAdapter = namedRows.find((candidate) => candidate?.siteAdapter === "bilibili");
  assert.ok(namedAdapter, "有标题时合成页面适配器行");
  assert.equal(mediaUtils.filenameHintSourceFor(namedAdapter), "titleDerived");
});

test("a real title that happens to contain a brand word keeps titleDerived trust", () => {
  // 子串判定曾把这些真实标题误当成泛化站点标签：面板退回品牌页标题，
  // App 侧落盘名变成 "YouTube.mp4"。占位名只能按词条全串相等判定。
  const titles = [
    "YouTube Rewind 2018",
    "【官方】哔哩哔哩弹幕网宣传曲",
    "国语精选合集 第3话",
    "Home Alone 4K Remastered",
  ];
  for (const title of titles) {
    assert.equal(
      mediaUtils.filenameHintSourceFor({
        url: "https://www.youtube.com/watch?v=vid12345678",
        siteAdapter: "youtube",
        filenameHint: `${title}.mp4`,
      }),
      "titleDerived",
      title,
    );
  }
  // 显示路径与线路标注同口径：品牌页标题不再压过具体卡片名。
  assert.equal(
    mediaUtils.smartMediaName(
      { siteAdapter: "youtube", filenameHint: "Home Alone 4K Remastered.mp4" },
      "YouTube",
      1,
      "www.youtube.com",
    ),
    "Home Alone 4K Remastered.mp4",
  );
});

test("an m4s pair named by the placeholder label is not title-derived", () => {
  // 列表页/卡片标题场景下上游会把合成标题置空（content-script synthesisTitle、
  // overlay coalesceCandidates），配对行于是回落到 "视频（{cid}）" 占位标签；
  // 该名字不由任何具体标题合成，不得在 App 命名链中压过真实标题。
  const mirror = "https://upos-sz-mirrorcos.bilivideo.cn/upgcxcode/63/29/123456789";
  const video = { url: `${mirror}/123456789-1-30080.m4s?e=1`, format: "video", mime: "video/mp4", supported: true, size: 9_000_000 };
  const audio = { url: `${mirror}/123456789-1-30280.m4s?e=1`, format: "audio", mime: "audio/mp4", supported: true, size: 3_000_000 };
  const watchlater = "https://www.bilibili.com/list/watchlater?bvid=BV1abcDEFghi";

  const pair = mediaUtils.coalesceMediaCandidates([video, audio], "", watchlater)
    .find((candidate) => candidate?.pairKind === "m4s-pair");
  assert.ok(pair, "空标题下仍必须合成 m4s 配对行");
  assert.equal(pair.filenameHintSource, "urlPath", "合成点必须自己声明来源");
  assert.equal(mediaUtils.filenameHintSourceFor(pair), "urlPath");
  assert.equal(
    mediaUtils.smartMediaName(pair, "真实卡片标题", 1, "www.bilibili.com"),
    "真实卡片标题",
    "占位名不得压过真实卡片标题",
  );

  const named = mediaUtils.coalesceMediaCandidates([video, audio], "某个具体视频标题", "https://www.bilibili.com/video/BV1abcDEFghi")
    .find((candidate) => candidate?.pairKind === "m4s-pair");
  assert.ok(named, "有标题时合成 m4s 配对行");
  assert.equal(named.filenameHint, "某个具体视频标题.mp4");
  assert.equal(mediaUtils.filenameHintSourceFor(named), "titleDerived");

  // 未声明来源的旧快照/转发候选走安全网：参数化占位标签按形状全串相等。
  assert.equal(
    mediaUtils.filenameHintSourceFor({ pairKind: "m4s-pair", filenameHint: "视频（123456789）.mp4" }),
    "urlPath",
  );
  // 形状相似但带真实内容的名字不得被误伤。
  assert.equal(
    mediaUtils.filenameHintSourceFor({ pairKind: "m4s-pair", filenameHint: "视频（123456789）幕后花絮.mp4" }),
    "titleDerived",
  );
});

test("a browser-resolved name keeps its authority", () => {
  // 服务器 Content-Disposition / 浏览器下载项解析名是权威来源：既不被占位名
  // 安全网降级，也不被 siteAdapter/pairKind 推断覆盖（技术规范 §8.1）。
  assert.equal(
    mediaUtils.filenameHintSourceFor({ filenameHintSource: "browserResolved", filenameHint: "Bilibili 媒体.mp4" }),
    "browserResolved",
  );
  assert.equal(
    mediaUtils.filenameHintSourceFor({ filenameHintSource: "browserResolved", filenameHint: "setup-1.2.3.dmg" }),
    "browserResolved",
  );
});

test("smartMediaName never appends a placeholder label as a disambiguator", () => {
  // 多候选时 hint 作为区分后缀，但占位标签没有区分价值：真机 B 站稍后再看
  // 页面曾显示 "霍尔木兹海峡…| 中国坐标 · Bilibili 媒体.mp4"。
  assert.equal(
    mediaUtils.smartMediaName(
      { siteAdapter: "bilibili", filenameHint: "Bilibili 媒体.mp4" },
      "霍尔木兹海峡被掉半年，谁在为能源海啮买单？| 中国坐标",
      3,
      "www.bilibili.com",
    ),
    "霍尔木兹海峡被掉半年，谁在为能源海啮买单？| 中国坐标",
  );
});

test("smartMediaName treats download/master placeholders as generic", () => {
  // "download" 与 "master" 都在泛化清单里：多候选时也不拼进显示名。
  assert.equal(
    mediaUtils.smartMediaName({ filenameHint: "download.mp4" }, "课程标题", 2),
    "课程标题",
  );
  assert.equal(
    mediaUtils.smartMediaName({ filenameHint: "master.mp4" }, "课程标题", 2),
    "课程标题",
  );
  // 非泛化 hint 在多候选时作为区分后缀保留。
  assert.equal(
    mediaUtils.smartMediaName({ filenameHint: "720p.mp4" }, "课程标题", 2),
    "课程标题 · 720p.mp4",
  );
});

test("generic placeholder word lists stay identical across JS and Swift", async () => {
  const expected = [
    "audio", "download", "index", "manifest", "master", "media", "playlist", "video",
  ];
  const overlaySource = await readFile(
    new URL("../../../BrowserExtension/chrome/src/content/overlay.js", import.meta.url),
    "utf8",
  );
  const swiftSource = await readFile(
    new URL("../../../Sources/MacIDMApp/Presentation/DownloadNaming.swift", import.meta.url),
    "utf8",
  );

  // 两份 JS 泛化正则（media-utils 的 smartMediaName 与 overlay 的降级副本）。
  for (const jsSource of [source, overlaySource]) {
    const match = jsSource.match(/\^\((download\|[^)]+)\)\\b\/i/);
    assert.ok(match, "JS 源码必须包含泛化名正则，且以 download 开头");
    assert.deepEqual(match[1].split("|").sort(), expected);
  }

  // Swift 侧 isGenericFilename 的基词数组。
  const swiftMatch = swiftSource.match(/return \[\s*([^\]]+)\]\.contains\(base\)/);
  assert.ok(swiftMatch, "Swift 源码必须包含泛化基词清单");
  const swiftWords = [...swiftMatch[1].matchAll(/"([a-z]+)"/g)].map((m) => m[1]).sort();
  assert.deepEqual(swiftWords, expected);
});

test("brand tail lists stay identical across JS and Swift", async () => {
  // 页级标题的品牌尾巴在两端各剥一次：扩展 stripBrandSuffix（显示名）与
  // App DownloadNaming.semanticPageTitle（落盘名）。清单漂移会让落盘名带着
  // 扩展已经剥掉的中文品牌名（如 "某视频_哔哩哔哩"、"…-哔哩哔哩视频"）。
  const jsTokens = source.match(/BRAND_TAIL_TOKENS = "([^"]+)"/);
  const jsWords = source.match(/BRAND_TAIL_MEDIA_WORDS = "([^"]+)"/);
  assert.ok(jsTokens, "media-utils.js 必须导出 BRAND_TAIL_TOKENS 品牌词表");
  assert.ok(jsWords, "media-utils.js 必须导出 BRAND_TAIL_MEDIA_WORDS 媒体词表");
  const swiftSource = await readFile(
    new URL("../../../Sources/MacIDMApp/Presentation/DownloadNaming.swift", import.meta.url),
    "utf8",
  );
  const swiftTokens = swiftSource.match(/brandTailTokens: Set<String> = \[\s*([^\]]+)\]/);
  const swiftWords = swiftSource.match(/brandTailMediaWords: Set<String> = \[\s*([^\]]+)\]/);
  assert.ok(swiftTokens, "DownloadNaming.swift 必须包含 brandTailTokens 清单");
  assert.ok(swiftWords, "DownloadNaming.swift 必须包含 brandTailMediaWords 清单");

  const unique = (values) => [...new Set(values.map((value) => value.trim().toLowerCase()))].sort();
  // 正则里的可选后缀（"videos?"）展开为两个词，与 Swift 的显式清单对齐。
  const expand = (alternation) => unique(
    alternation.split("|").flatMap((part) => {
      const token = part.trim();
      return token.endsWith("?") ? [token.slice(0, -2), token.slice(0, -1)] : [token];
    }),
  );
  const swiftList = (match) => unique([...match[1].matchAll(/"([^"]+)"/g)].map((m) => m[1]));

  assert.deepEqual(swiftList(swiftTokens), expand(jsTokens[1]));
  assert.deepEqual(swiftList(swiftWords), expand(jsWords[1]));
  assert.ok(expand(jsTokens[1]).includes("哔哩哔哩"), "品牌词表必须含中文品牌名");
  assert.ok(expand(jsWords[1]).includes("视频"), "媒体词表必须含中文泛化词");
});
