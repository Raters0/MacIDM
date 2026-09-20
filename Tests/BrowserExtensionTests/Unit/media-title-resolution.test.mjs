import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const source = await readFile(
  new URL("../../../BrowserExtension/chrome/src/shared/media-utils.js", import.meta.url),
  "utf8",
);

function makeContext({ hostname, href }) {
  const context = vm.createContext({ URL, location: { hostname, href } });
  context.globalThis = context;
  vm.runInContext(source, context);
  return context;
}

// Minimal fake DOM: a module container exposing one heading, plus an anchor
// whose closest() resolves only the generic "article" module selector.
function makeDoc({ descText = null, headingText = "My great video title", title = "" } = {}) {
  const heading = { textContent: headingText };
  const body = {
    querySelectorAll: (selector) =>
      String(selector).includes("heading") ? [heading] : [],
    querySelector: () => null,
  };
  return {
    title,
    body,
    documentElement: body,
    querySelector: (selector) =>
      selector === '[data-e2e="video-desc"]' && descText != null
        ? { textContent: descText }
        : null,
    querySelectorAll: () => [],
  };
}
function makeAnchor(module) {
  return { closest: (selector) => (selector === "article" ? module : null) };
}

test("stripBrandSuffix removes trailing Chinese and English brand suffixes", () => {
  const { MacIDMMediaUtils: u } = makeContext({ hostname: "www.douyin.com", href: "https://www.douyin.com/" });
  assert.equal(u.stripBrandSuffix("某视频标题 - 抖音"), "某视频标题");
  assert.equal(u.stripBrandSuffix("Some title | YouTube"), "Some title");
  assert.equal(u.stripBrandSuffix("No suffix here"), "No suffix here");
});

// Bilibili's og:title and document.title stack two underscore-separated
// brand tails ("标题_哔哩哔哩_bilibili"). If stripBrandSuffix leaves either
// tail in place, isGenericOrBrandTitle flags the whole title as brand-only,
// content-script's synthesisTitle collapses to "", and the site adapter
// synthesizes filenameHint = "Bilibili 媒体.mp4" — the exact regression the
// user reported on the watch page.
test("stripBrandSuffix removes Bilibili underscore-separated double brand tails", () => {
  const { MacIDMMediaUtils: u } = makeContext({ hostname: "www.bilibili.com", href: "https://www.bilibili.com/video/BV1xx" });
  assert.equal(
    u.stripBrandSuffix("【补档，全球通缉武大】918活动找同名_哔哩哔哩_bilibili"),
    "【补档，全球通缉武大】918活动找同名",
  );
  assert.equal(u.stripBrandSuffix("某视频_bilibili"), "某视频");
  assert.equal(u.stripBrandSuffix("某视频_哔哩哔哩"), "某视频");
  // A real underscore inside the title (no brand tail) survives untouched.
  assert.equal(u.stripBrandSuffix("Episode_1"), "Episode_1");
  assert.equal(u.stripBrandSuffix("some_title_with_underscores"), "some_title_with_underscores");
  // Once stripped, the specific title is no longer brand/generic — this is
  // the invariant that keeps synthesisTitle non-empty on Bilibili watch pages.
  assert.equal(u.isGenericOrBrandTitle(u.stripBrandSuffix("某视频_哔哩哔哩_bilibili"), "www.bilibili.com"), false);
});

test("isGenericOrBrandTitle flags brand/empty titles and Chinese brand names", () => {
  const { MacIDMMediaUtils: u } = makeContext({ hostname: "www.douyin.com", href: "https://www.douyin.com/" });
  assert.equal(u.isGenericOrBrandTitle("", "www.douyin.com"), true);
  assert.equal(u.isGenericOrBrandTitle("抖音精选电脑版 - 抖音旗下优质视频平台", "www.douyin.com"), true);
  assert.equal(u.isGenericOrBrandTitle("【何同学】库克时代", "www.douyin.com"), false);
});

test("resolveContentTitle picks the heading inside the anchor's module", () => {
  const { MacIDMMediaUtils: u } = makeContext({ hostname: "www.example.com", href: "https://www.example.com/watch" });
  const doc = makeDoc({ headingText: "My great video title" });
  const anchor = makeAnchor(doc.body);
  assert.equal(u.resolveContentTitle(doc, anchor), "My great video title");
});

test("resolvePageTitle uses the Douyin video-desc fast-path and strips expand", () => {
  const { MacIDMMediaUtils: u } = makeContext({
    hostname: "www.douyin.com",
    href: "https://www.douyin.com/jingxuan?modal_id=1",
  });
  const doc = makeDoc({
    descText: "【何同学】库克时代 #抖音前沿科技首发计划 #苹果 展开",
    title: "抖音精选电脑版 - 抖音旗下优质视频平台",
  });
  assert.equal(u.resolvePageTitle(doc), "【何同学】库克时代 #抖音前沿科技首发计划 #苹果");
});

test("resolvePageTitle falls back to proximity title when document.title is generic", () => {
  const { MacIDMMediaUtils: u } = makeContext({ hostname: "www.example.com", href: "https://www.example.com/home" });
  const doc = makeDoc({ headingText: "My great video title", title: "Example Home" });
  assert.equal(u.resolvePageTitle(doc, makeAnchor(doc.body)), "My great video title");
});

test("resolvePageTitle keeps a specific document.title when no anchor is given", () => {
  const { MacIDMMediaUtils: u } = makeContext({ hostname: "www.example.com", href: "https://www.example.com/post" });
  const doc = makeDoc({ headingText: "Some sidebar heading", title: "My specific article - Example" });
  assert.equal(u.resolvePageTitle(doc, null), "My specific article");
});

test("stripHostSuffix mirrors the App's semanticPageTitle host-matched strip", () => {
  const { MacIDMMediaUtils: u } = makeContext({ hostname: "www.bilibili.com", href: "https://www.bilibili.com/" });
  assert.equal(
    u.stripHostSuffix("哔哩哔哩 (゜-゜)つロ 干杯~-bilibili", "www.bilibili.com"),
    "哔哩哔哩 (゜-゜)つロ 干杯~",
  );
  assert.equal(u.stripHostSuffix("某视频 - bilibili", "bilibili.com"), "某视频");
  // Real titles containing separators survive: the suffix is not a host token.
  assert.equal(u.stripHostSuffix("Love is War - Episode 3", "www.bilibili.com"), "Love is War - Episode 3");
  assert.equal(u.stripHostSuffix("No separator", "www.bilibili.com"), "No separator");
});

// Douyin/Bilibili hover cards: the player shell wrapping the preview video
// carries no heading; the caption lives in the enclosing card. The resolver
// must walk outward instead of trapping the pool inside the empty shell.
// Bilibili watch page: the player module's subtitle/quality menus carry long
// title-like text; chrome containers must be excluded from the pool so the
// walk reaches the page heading.
test("resolveContentTitle excludes player chrome containers (subtitle menu) from the pool", () => {
  const { MacIDMMediaUtils: u } = makeContext({ hostname: "www.bilibili.com", href: "https://www.bilibili.com/video/BV1xx" });
  const h1 = { textContent: "【官方 MV】Never Gonna Give You Up" };
  const body = {
    nodeType: 1,
    matches: () => false,
    parentElement: null,
    querySelectorAll: (selector) => (String(selector).includes("heading") ? [h1] : []),
  };
  const subtitlePanel = {
    nodeType: 1,
    matches: (selector) => selector === '[class*="subtitle"]',
    parentElement: null, // set below
  };
  const subtitleEntry = {
    textContent: "主字幕 中文（中国） English(US) 日本語",
    closest: (selector) => (selector === '[class*="subtitle"]' ? subtitlePanel : null),
  };
  subtitlePanel.parentElement = null;
  const player = {
    nodeType: 1,
    matches: (selector) => selector === '[class*="player"]',
    parentElement: body,
    querySelectorAll: (selector) => (selector === "*"
      ? []
      : (String(selector).includes("heading") ? [] : [subtitleEntry])),
    getBoundingClientRect: () => ({ width: 900, height: 500 }),
  };
  // subtitlePanel lives inside the player module.
  const panelChain = { parentElement: player };
  subtitlePanel.parentElement = panelChain;
  // containsNode walk: subtitleEntry has no parentElement chain into player,
  // so mirror containment via closest hit chain instead.
  subtitleEntry.parentElement = subtitlePanel;
  const video = { nodeType: 1, matches: () => false, parentElement: player };
  const doc = {
    title: "【官方 MV】Never Gonna Give You Up - Rick Astley_哔哩哔哩_bilibili",
    body,
    documentElement: body,
    querySelector: () => null,
  };
  assert.equal(u.resolveContentTitle(doc, video), "【官方 MV】Never Gonna Give You Up");
});

test("resolveContentTitle excludes player error/notice banners whose class contains 'title'", () => {
  const { MacIDMMediaUtils: u } = makeContext({ hostname: "www.bilibili.com", href: "https://www.bilibili.com/video/BV1xx" });
  const h1 = { textContent: "【守望先锋教学】如何成为一个笨蛋长枪" };
  const body = {
    nodeType: 1,
    matches: () => false,
    parentElement: null,
    querySelectorAll: (selector) => (String(selector).includes("heading") ? [h1] : []),
  };
  const errorWrap = { nodeType: 1, parentElement: null };
  const notice = {
    textContent: "您的浏览器还未开启本地网络访问权限，可能会影响视频内容的正常播放。",
    closest: (selector) => (String(selector).includes("error") ? errorWrap : null),
    parentElement: errorWrap,
  };
  const player = {
    nodeType: 1,
    matches: (selector) => selector === '[class*="player"]',
    parentElement: body,
    querySelectorAll: (selector) => (selector === "*"
      ? []
      : (String(selector).includes("heading") ? [] : [notice])),
    getBoundingClientRect: () => ({ width: 900, height: 500 }),
  };
  errorWrap.parentElement = player;
  const video = { nodeType: 1, matches: () => false, parentElement: player };
  const doc = {
    title: "【守望先锋教学】如何成为一个笨蛋长枪_哔哩哔哩_bilibili",
    body,
    documentElement: body,
    querySelector: () => null,
  };
  assert.equal(u.resolveContentTitle(doc, video), "【守望先锋教学】如何成为一个笨蛋长枪");
});

test("resolveContentTitle falls back to bare leaf captions inside card modules", () => {
  const { MacIDMMediaUtils: u } = makeContext({ hostname: "www.douyin.com", href: "https://www.douyin.com/jingxuan" });
  const caption = { textContent: "一口气看完《悬案》深度解读完整版", children: [], closest: () => null };
  const author = { textContent: "0v0前天", children: [], closest: () => null };
  const page = { nodeType: 1, matches: () => false, parentElement: null };
  const card = {
    nodeType: 1,
    matches: (selector) => selector === '[class*="card"]',
    parentElement: page,
    querySelectorAll: (selector) => (selector === "*" ? [caption, author] : []),
    getBoundingClientRect: () => ({ width: 320, height: 420 }),
  };
  const shell = {
    nodeType: 1,
    matches: (selector) => selector === '[class*="player"]',
    parentElement: card,
    querySelectorAll: () => [],
    getBoundingClientRect: () => ({ width: 320, height: 320 }),
  };
  const anchor = { nodeType: 1, matches: () => false, parentElement: shell };
  const doc = {
    title: "抖音精选电脑版 - 抖音旗下优质视频平台",
    body: { querySelectorAll: () => [] },
    documentElement: { querySelectorAll: () => [] },
    querySelector: () => null,
  };
  assert.equal(u.resolveContentTitle(doc, anchor), "一口气看完《悬案》深度解读完整版");
});

test("resolveContentTitle skips player chrome text (buffer tip, chapter timecode) and stops at the card caption", () => {
  const { MacIDMMediaUtils: u } = makeContext({ hostname: "www.bilibili.com", href: "https://www.bilibili.com/" });
  const cardHeading = { textContent: "生活中最阴的概念神实力排行（2）" };
  const page = { nodeType: 1, matches: () => false, parentElement: null };
  const card = {
    nodeType: 1,
    matches: (selector) => selector === '[class*="card"]',
    querySelectorAll: (selector) =>
      String(selector).includes("heading") ? [cardHeading] : [],
    getBoundingClientRect: () => ({ width: 320, height: 420 }),
    parentElement: page,
  };
  // Player shell pool: a buffer tip (short, low score) and a chapter marker
  // with a mm:ss timecode — neither may stop the outward walk.
  const bufferTip = { textContent: "正在缓冲" };
  const chapter = { textContent: "莉莉斯00:57" };
  const shell = {
    nodeType: 1,
    matches: (selector) => selector === '[class*="player"]',
    querySelectorAll: (selector) =>
      String(selector).includes("heading") ? [] : [bufferTip, chapter],
    getBoundingClientRect: () => ({ width: 320, height: 320 }),
    parentElement: card,
  };
  const anchor = { nodeType: 1, matches: () => false, parentElement: shell };
  const doc = {
    title: "哔哩哔哩 (゜-゜)つロ 干杯~-bilibili",
    body: { querySelectorAll: () => [] },
    documentElement: { querySelectorAll: () => [] },
    querySelector: () => null,
  };
  assert.equal(u.resolveContentTitle(doc, anchor), "生活中最阴的概念神实力排行（2）");
});

test("resolveContentTitle walks outward from an empty player shell to the card", () => {
  const { MacIDMMediaUtils: u } = makeContext({ hostname: "www.douyin.com", href: "https://www.douyin.com/jingxuan" });
  const cardHeading = { textContent: "全斗焕的野心是怎样被喂大的？" };
  const page = { nodeType: 1, matches: () => false, parentElement: null };
  const card = {
    nodeType: 1,
    matches: (selector) => selector === '[class*="card"]',
    querySelectorAll: (selector) =>
      String(selector).includes("heading") ? [] : [cardHeading],
    getBoundingClientRect: () => ({ width: 320, height: 420 }),
    parentElement: page,
  };
  const shell = {
    nodeType: 1,
    matches: (selector) => selector === '[class*="player"]',
    querySelectorAll: () => [],
    getBoundingClientRect: () => ({ width: 320, height: 320 }),
    parentElement: card,
  };
  const anchor = { nodeType: 1, matches: () => false, parentElement: shell };
  const doc = {
    title: "抖音精选电脑版 - 抖音旗下优质视频平台",
    body: { querySelectorAll: () => [] },
    documentElement: { querySelectorAll: () => [] },
    querySelector: () => null,
  };
  assert.equal(u.resolveContentTitle(doc, anchor), "全斗焕的野心是怎样被喂大的？");
});

test("resolveContentTitle ignores hover-revealed watch-later button labels in the leaf pool", () => {
  const { MacIDMMediaUtils: u } = makeContext({ hostname: "www.douyin.com", href: "https://www.douyin.com/jingxuan" });
  const page = { nodeType: 1, matches: () => false, parentElement: null };
  const card = {
    nodeType: 1,
    matches: (selector) => selector === '[class*="card"]',
    parentElement: page,
    getBoundingClientRect: () => ({ width: 320, height: 420 }),
  };
  const caption = { textContent: "这碗皮子拌面，谁吃谁迷糊", children: [], closest: () => null, parentElement: card };
  // Hover toolbar button: short clean CJK label that reads like a caption.
  const watchLater = { textContent: "添加至稍后再看", children: [], parentElement: card };
  watchLater.closest = (selector) => (selector === "button" || selector === '[role="button"]' ? watchLater : null);
  card.querySelectorAll = (selector) => (selector === "*" ? [caption, watchLater] : []);
  const shell = {
    nodeType: 1,
    matches: (selector) => selector === '[class*="player"]',
    parentElement: card,
    querySelectorAll: () => [],
    getBoundingClientRect: () => ({ width: 320, height: 320 }),
  };
  const anchor = { nodeType: 1, matches: () => false, parentElement: shell };
  const doc = {
    title: "抖音精选电脑版 - 抖音旗下优质视频平台",
    body: { querySelectorAll: () => [] },
    documentElement: { querySelectorAll: () => [] },
    querySelector: () => null,
  };
  assert.equal(u.resolveContentTitle(doc, anchor), "这碗皮子拌面，谁吃谁迷糊");
});

test("smartMediaName follows the App trust model: identity hints win, brand titles never prefix", () => {
  const { MacIDMMediaUtils: u } = makeContext({ hostname: "www.bilibili.com", href: "https://www.bilibili.com/" });
  const branding = "哔哩哔哩 (゜-゜)つロ 干杯~-bilibili";
  // titleDerived identity names outrank any page title (App naming chain).
  const adapter = { filenameHint: "卡片标题.mp4", siteAdapter: "bilibili" };
  assert.equal(u.smartMediaName(adapter, branding, 2, "www.bilibili.com"), "卡片标题.mp4");
  // A generic/brand page title is never used as a prefix; with no identity
  // name it remains only as the last readable fallback.
  const plain = { filenameHint: "v02033gig000.mp4" };
  assert.equal(u.smartMediaName(plain, branding, 2, "www.bilibili.com"), "哔哩哔哩 (゜-゜)つロ 干杯~");
  // A specific page title still disambiguates multiple candidates.
  assert.equal(
    u.smartMediaName(plain, "【何同学】库克时代", 2, "www.douyin.com"),
    "【何同学】库克时代 · v02033gig000.mp4",
  );
});

test("resolveContentTitle accepts caption containers whose children are inline spans", () => {
  const ctx = makeContext({ hostname: "www.douyin.com", href: "https://www.douyin.com/jingxuan" });
  ctx.getComputedStyle = () => ({ display: "inline" });
  const { MacIDMMediaUtils: u } = ctx;
  const hashtag = { textContent: "#深度解析", children: [] };
  const caption = { textContent: "一口气看完《悬案》深度解读完整版", children: [hashtag] };
  const authorLeaf = { textContent: "0v0", children: [] };
  const dateLeaf = { textContent: "前天", children: [] };
  const authorRow = { textContent: "0v0前天", children: [authorLeaf, dateLeaf] };
  const page = { nodeType: 1, matches: () => false, parentElement: null };
  const card = {
    nodeType: 1,
    matches: (selector) => selector === '[class*="card"]',
    parentElement: page,
    querySelectorAll: (selector) => (selector === "*" ? [caption, hashtag, authorRow, authorLeaf, dateLeaf] : []),
    getBoundingClientRect: () => ({ width: 320, height: 420 }),
  };
  const anchor = { nodeType: 1, matches: () => false, parentElement: card };
  const doc = {
    title: "抖音精选电脑版 - 抖音旗下优质视频平台",
    body: { querySelectorAll: () => [] },
    documentElement: { querySelectorAll: () => [] },
    querySelector: () => null,
  };
  assert.equal(u.resolveContentTitle(doc, anchor), "一口气看完《悬案》深度解读完整版");
});

for (const caption of ["你的胆子肥嘟嘟 #付航脱口秀 #付航", "分享", "00:57", "#日常", "好".repeat(160)]) {
  test(`Douyin semantic caption beats author/time and heuristic rejection: ${caption.slice(0, 20)}`, () => {
    const { MacIDMMediaUtils: u } = makeContext({ hostname: "www.douyin.com", href: "https://www.douyin.com/jingxuan" });
    const doc = makeDoc({ headingText: "莉莉斯18分钟前", descText: "另一个播放器的描述" });
    const card = { querySelector: selector => selector.includes("data-feed-ad-click-refer") ? { textContent: caption } : null };
    const anchor = { closest: selector => selector.includes("jingxuanVideoCard") ? card : null };
    assert.equal(u.resolveContentTitle(doc, anchor), caption);
    assert.equal(u.resolvePageTitle(doc, anchor), caption);
  });
}

test("Douyin detail title belongs to the anchored player, not preload or chapter summary", () => {
  const { MacIDMMediaUtils: u } = makeContext({ hostname: "www.douyin.com", href: "https://www.douyin.com/jingxuan?modal_id=1" });
  const doc = makeDoc({ descText: "预加载视频", headingText: "在日本便利店为栗子挑选晚餐" });
  // 抖音自家播放器容器（playerContainer）与 xgplayer 同等对待
  const player = { querySelector: () => ({ textContent: "栗子的伙食真不是一般人能吃的" }) };
  const anchor = { closest: selector => selector.includes("xgplayer") || selector.includes("playerContainer") ? player : null };
  assert.equal(u.resolveContentTitle(doc, anchor), "栗子的伙食真不是一般人能吃的");
});

// X places a visually hidden accessibility H2 at body level ("要查看键盘
// 快捷键，按下问号" + "查看键盘快捷键"). It reads like a real heading and
// outranks short captions, but never renders — it must not win the title pool.
test("visually hidden a11y headings never win the content-title pool", () => {
  const context = makeContext({ hostname: "www.example.com", href: "https://www.example.com/status/1" });
  const { MacIDMMediaUtils: u } = context;
  const visibleHeading = { textContent: "真实的推文视频标题" };
  const a11yHeading = {
    textContent: "要查看键盘快捷键，按下问号查看键盘快捷键",
    getBoundingClientRect: () => ({ width: 1, height: 1 }),
  };
  context.getComputedStyle = (element) =>
    element === a11yHeading
      ? { display: "flex", visibility: "visible", clip: "rect(1px, 1px, 1px, 1px)", position: "absolute" }
      : {};
  const body = {
    querySelectorAll: (selector) =>
      String(selector).includes("heading") ? [a11yHeading, visibleHeading] : [],
    querySelector: () => null,
  };
  const doc = { title: "X", body, documentElement: body, querySelector: () => null, querySelectorAll: () => [] };
  assert.equal(
    u.resolveContentTitle(doc, null),
    "真实的推文视频标题",
    "视觉隐藏的 a11y heading 不得命中标题池",
  );
});

// Without layout information (unit shims) an element must degrade to
// "visible", never to "hidden" — otherwise every real heading would be
// filtered out in environments without a renderer.
test("headings without layout information stay eligible for the title pool", () => {
  const { MacIDMMediaUtils: u } = makeContext({ hostname: "www.example.com", href: "https://www.example.com/status/2" });
  const heading = { textContent: "无布局环境里的标题" };
  const body = {
    querySelectorAll: (selector) => (String(selector).includes("heading") ? [heading] : []),
    querySelector: () => null,
  };
  const doc = { title: "X", body, documentElement: body, querySelector: () => null, querySelectorAll: () => [] };
  assert.equal(u.resolveContentTitle(doc, null), "无布局环境里的标题");
});

// X/Twitter: the tweet body carries no heading/[class*='title'] (obfuscated
// classes), so the outward walk used to reach the page body and pick a
// visible chrome heading (the composer prompt). [data-testid='tweetText']
// must enter the pool inside the tweet module and win before the body.
test("X tweetText outranks visible chrome headings in the body pool", () => {
  const { MacIDMMediaUtils: u } = makeContext({ hostname: "www.example.com", href: "https://www.example.com/status/3" });
  const tweetText = { textContent: "放学学生乱跑家长在追，自己填，在玩捉迷藏，恋童癖集美追逐放学的时代" };
  const tweetModule = {
    nodeType: 1,
    matches: (selector) => selector === "article",
    parentElement: null,
    querySelectorAll: (selector) => (String(selector).includes("tweetText") ? [tweetText] : []),
    querySelector: () => null,
    getBoundingClientRect: () => ({ width: 500, height: 400 }),
  };
  const composerHeading = { textContent: "有什么新鲜事" };
  const body = {
    querySelectorAll: (selector) => (String(selector).includes("heading") ? [composerHeading] : []),
    querySelector: () => null,
  };
  const doc = { title: "X", body, documentElement: body, querySelector: () => null, querySelectorAll: () => [] };
  const anchor = {
    nodeType: 1,
    matches: () => false,
    parentElement: tweetModule,
  };
  assert.equal(
    u.resolveContentTitle(doc, anchor),
    "放学学生乱跑家长在追，自己填，在玩捉迷藏，恋童癖集美追逐放学的时代",
  );
});

// ===== 抖音详情弹幕标题 / feed 旧标题残留（Round 2）=====

function makeDouyinDoc({ descNode = null } = {}) {
  // doc 级无 desc；desc 挂在归属容器（弹窗/详情 scope）上由用例注入
  return {
    title: "抖音 - 主流",
    body: { querySelectorAll: () => [], querySelector: () => null },
    documentElement: null,
    querySelector: (selector) =>
      String(selector).includes("video-desc") && descNode ? descNode : null,
    querySelectorAll: () => [],
  };
}

// 回归：抖音精选详情弹窗用的是自家播放器（class 含 playerContainer，而非
// xgplayer）。守卫漏掉它时，解析器落到播放器模块的通用池，弹幕文本会当
// 标题胜出。修复后：desc 在归属容器里 → 取 desc；desc 全缺 → 返回 ""。
test("douyin detail resolves video-desc through playerContainer scope, never danmaku", () => {
  const { MacIDMMediaUtils: u } = makeContext({
    hostname: "www.douyin.com",
    href: "https://www.douyin.com/jingxuan?modal_id=7675738301332065572",
  });
  const descNode = { textContent: "  正确的 video-desc 描述标题  " };
  const modalScope = {
    nodeType: 1,
    parentElement: null,
    querySelector: (selector) =>
      String(selector).includes("video-desc") ? descNode : null,
    querySelectorAll: () => [],
  };
  const player = {
    nodeType: 1,
    parentElement: modalScope,
    closest: (selector) => (String(selector).includes("playerContainer") ? player : null),
    querySelector: () => null,
    querySelectorAll: () => [],
  };
  const anchor = {
    nodeType: 1,
    closest: (selector) => (String(selector).includes("playerContainer") ? player : null),
  };
  assert.equal(
    u.resolveContentTitle(makeDouyinDoc(), anchor),
    "正确的 video-desc 描述标题",
    "playerContainer 守卫命中后应从归属容器取 video-desc",
  );

  // desc 全缺：返回 ""，绝不落回播放器内的弹幕文本
  const modalNoDesc = {
    nodeType: 1,
    parentElement: null,
    querySelector: () => null,
    querySelectorAll: () => [],
  };
  const playerNoDesc = {
    nodeType: 1,
    parentElement: modalNoDesc,
    closest: (selector) => (String(selector).includes("playerContainer") ? playerNoDesc : null),
    querySelector: () => null,
    querySelectorAll: () => [],
  };
  const anchorNoDesc = {
    nodeType: 1,
    closest: (selector) => (String(selector).includes("playerContainer") ? playerNoDesc : null),
  };
  assert.equal(
    u.resolveContentTitle(makeDouyinDoc(), anchorNoDesc),
    "",
    "desc 缺失时必须放弃，不得使用弹幕/近似标题",
  );
});

// 回归：抖音 SPA 关闭详情弹窗后 document.title 残留上一个视频标题，feed 上
// 页级标题整体不可信；无卡片归属的元素（残留播放器）不得冒用旧标题。
test("douyin feed distrusts stale page-level titles; card captions still win", () => {
  const { MacIDMMediaUtils: u } = makeContext({
    hostname: "www.douyin.com",
    href: "https://www.douyin.com/jingxuan",
  });
  const staleDoc = {
    title: "无赫之仇震撼来袭，瘸腿劳工的往事。 #韩剧 #动作 - 抖音",
    body: { querySelectorAll: () => [], querySelector: () => null },
    documentElement: null,
    querySelector: (selector) => {
      if (String(selector).includes("og:title")) {
        return { getAttribute: () => "无赫之仇震撼来袭，瘸腿劳工的往事。" };
      }
      return null;
    },
    querySelectorAll: () => [],
  };
  assert.equal(u.resolvePageTitle(staleDoc, null), "", "feed 上页级标题不可信");
  const bareAnchor = { nodeType: 1, closest: () => null };
  assert.equal(
    u.resolveContentTitle(staleDoc, bareAnchor),
    "",
    "feed 上无卡片归属的元素不得冒用旧详情标题",
  );

  // 卡片语义字段不受影响：feed 上卡片行仍用 caption
  const caption = { textContent: " 把一切都毁掉！二代暴君禅院真希浴血重生！ " };
  const card = {
    nodeType: 1,
    querySelector: (selector) =>
      String(selector).includes("data-feed-ad-click-refer") ? caption : null,
  };
  const cardAnchor = {
    nodeType: 1,
    closest: (selector) =>
      String(selector).includes("jingxuanVideoCard") || String(selector).includes("waterfall-videoCardContainer")
        ? card
        : null,
  };
  assert.equal(
    u.resolveContentTitle(staleDoc, cardAnchor),
    "把一切都毁掉！二代暴君禅院真希浴血重生！",
    "feed 卡片行仍使用语义 caption",
  );
});

// 用户要求：X 文件名只保留 URL 路径里的媒体 ID。X host 的标题推导
// （内容级与页级）整体禁用——推文正文/alt/og 均不可信（营销账号、
// 推荐区串扰），置空后 filenameHint 回落 urlPath、App 侧 pageTitle 为空。
test("X host disables content and page title derivation", () => {
  const { MacIDMMediaUtils: u } = makeContext({
    hostname: "x.com",
    href: "https://x.com/someone/status/2100201778415325184",
  });
  const tweetText = { textContent: "点主页🌸线下资源🍎1-5线同步更新看简介" };
  const module = {
    nodeType: 1,
    matches: (selector) => selector === "article",
    parentElement: null,
    querySelectorAll: (selector) => (String(selector).includes("tweetText") ? [tweetText] : []),
    querySelector: () => null,
    getBoundingClientRect: () => ({ width: 500, height: 400 }),
  };
  const body = {
    querySelectorAll: () => [tweetText],
    querySelector: () => null,
  };
  const doc = {
    title: "点主页🌸线下资源 on X",
    body,
    documentElement: body,
    querySelector: () => null,
    querySelectorAll: () => [],
  };
  const anchor = {
    nodeType: 1,
    matches: () => false,
    parentElement: module,
    closest: (selector) => (module.matches(selector) ? module : null),
    querySelectorAll: () => [],
    getBoundingClientRect: () => ({ width: 400, height: 300 }),
  };
  assert.equal(u.resolveContentTitle(doc, anchor), "");
  assert.equal(u.resolvePageTitle(doc, anchor), "");
  assert.equal(u.resolvePageTitle(doc, null), "");
});
