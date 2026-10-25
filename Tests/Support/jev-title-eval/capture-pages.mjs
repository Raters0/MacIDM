// Jev 标题评测 · 阶段 1：真实页面抓取（chrome-extension-spec 场景复现）。
//
// 在真实浏览器里打开 B 站 / 抖音 / YouTube 的首页与详情页，注入生产
// media-utils.js 在真实 DOM 上跑出「我们自己的规则」基线标题，再用一份
// 零站点知识的通用候选收割器收集提交给 Jev 的候选字符串。
//
// 用法：node capture-pages.mjs <outdir>
// 输出：<outdir>/pages.json（页面快照结构）与 <outdir>/shots/*.png。
// 本脚本不读取、不存储任何凭据；页面数据只落在调用方指定的目录。
//
// 证据边界（Tests/AGENTS.md）：这是真实站点 HTML 证据，不是扩展端到端
// 证据；YouTube 首页基线读取的是预览播放器 getVideoData()，与生产桥
// youtube-player-bridge.js readPreviewIdentity() 同源同字段。

import { readFileSync, writeFileSync, mkdirSync, existsSync, readdirSync } from "node:fs";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";

const REPO_ROOT = fileURLToPath(new URL("../../..", import.meta.url));
const MEDIA_UTILS_PATH = join(REPO_ROOT, "BrowserExtension/chrome/src/shared/media-utils.js");
const OUT_DIR = process.argv[2] ?? join(tmpdir(), "macidm-jev-eval", "pages");
const SHOT_DIR = join(OUT_DIR, "shots");

// playwright-core 不进仓库依赖：从临时目录解析（见 README）。
const playwrightCoreDir = process.env.PLAYWRIGHT_CORE_DIR
  ?? join(tmpdir(), "macidm-jev-eval");
const require = createRequire(join(playwrightCoreDir, "package.json"));
const { chromium } = require("playwright-core");

function findChromiumExecutable() {
  const cacheDir = join(homedir(), "Library/Caches/ms-playwright");
  if (existsSync(cacheDir)) {
    const versions = readdirSync(cacheDir)
      .filter((name) => /^chromium-\d+$/.test(name))
      .sort((a, b) => Number(b.slice(9)) - Number(a.slice(9)));
    for (const version of versions) {
      const candidate = join(
        cacheDir, version, "chrome-mac-arm64",
        "Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
      );
      if (existsSync(candidate)) return candidate;
    }
  }
  const systemChrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
  if (existsSync(systemChrome)) return systemChrome;
  throw new Error("no chromium executable found (ms-playwright cache or system Chrome)");
}

const mediaUtilsSource = readFileSync(MEDIA_UTILS_PATH, "utf8");

// ---------- 通用候选收割器（零站点知识；这是被测对象之一） ----------

const HARVEST_SOURCE = readFileSync(join(REPO_ROOT, "Tests/Support/jev-title-eval/generic-harvester.js"), "utf8");

const DOUYIN_DETAIL_EVAL_SOURCE = readFileSync(join(REPO_ROOT, "Tests/Support/jev-title-eval/douyin-detail-eval.js"), "utf8");

// ---------- 浏览器会话 ----------

const ERRORS = [];
const PAGES = [];

async function newPage(context, label) {
  const page = await context.newPage();
  page.setDefaultTimeout(20000);
  page.on("pageerror", () => {});
  return page;
}

async function shot(page, name) {
  try {
    mkdirSync(SHOT_DIR, { recursive: true });
    await page.screenshot({ path: join(SHOT_DIR, `${name}.png`), fullPage: false });
  } catch { /* 截图失败不影响抓取 */ }
}

async function inject(page) {
  await page.evaluate(mediaUtilsSource);
  await page.evaluate(HARVEST_SOURCE);
}

async function dismissModal(page, selectors) {
  for (const selector of selectors) {
    try {
      const node = page.locator(selector).first();
      if (await node.isVisible({ timeout: 1200 })) {
        await node.click({ timeout: 2000 });
        await page.waitForTimeout(600);
      }
    } catch { /* 无弹窗继续 */ }
  }
}

function meta(page) {
  return page.evaluate(() => ({
    documentTitle: document.title || "",
    ogTitle: document.querySelector('meta[property="og:title"]')?.content ?? "",
  }));
}

// ---------- Bilibili ----------

async function captureBilibili(context) {
  const site = "bilibili";
  const page = await newPage(context, site);
  try {
    await page.goto("https://www.bilibili.com/", { waitUntil: "domcontentloaded", timeout: 45000 });
  } catch (error) {
    ERRORS.push(`bilibili goto: ${error.message.split("\n")[0]}`);
  }
  await dismissModal(page, [
    ".bili-mini-mask .bili-mini-close-button",
    ".bili-mini-mask-close",
    "[aria-label='关闭']",
  ]);
  try {
    await page.waitForSelector(".bili-video-card", { timeout: 30000, state: "attached" });
  } catch (error) {
    await shot(page, "bilibili-home-timeout");
    const probe = await page.content().catch(() => "");
    const marker = probe.includes("bili-video-card") ? "card-class-present" : "card-class-absent";
    ERRORS.push(`bilibili waitForSelector: ${marker}, html ${probe.length}B`);
    throw error;
  }
  await inject(page);
  await page.waitForTimeout(2500);
  const { documentTitle, ogTitle } = await meta(page);

  const cardCount = await page.evaluate(() => document.querySelectorAll(".bili-video-card").length);
  const identityByBvid = new Map();
  const cards = [];
  const limit = Math.min(cardCount, 6);
  for (let index = 0; index < limit; index += 1) {
    const record = await page.evaluate(([index, harvest]) => {
      const card = document.querySelectorAll(".bili-video-card")[index];
      if (!card) return null;
      const link = card.querySelector("a[href*='/video/']");
      const href = link ? new URL(link.getAttribute("href"), location.origin).toString() : "";
      const bvid = (href.match(/\/video\/(BV[0-9A-Za-z]+)/) ?? [])[1] ?? "";
      const candidates = globalThis.MacIDMHarvest.harvestCard(card);
      const domTitle = textOrNull(card, "#video-title, h3");
      return { href, bvid, candidates, domTitle };
      function textOrNull(root, selector) {
        const el = root.querySelector(selector);
        return el ? String(el.textContent ?? "").replace(/\s+/gu, " ").trim().slice(0, 200) : "";
      }
    }, [index]);
    if (!record?.href) continue;
    // 悬停触发卡片内预览播放器，随后用生产 collectBilibiliPreviewIdentities 取基线。
    try {
      const cover = page.locator(".bili-video-card").nth(index).locator("a[href*='/video/']").first();
      await cover.scrollIntoViewIfNeeded();
      await cover.hover({ timeout: 5000 });
      await page.waitForTimeout(2600);
      const identities = await page.evaluate(
        () => globalThis.MacIDMMediaUtils.collectBilibiliPreviewIdentities(document, location.href),
      );
      for (const identity of identities) identityByBvid.set(identity.bvid, identity.title);
    } catch (error) {
      ERRORS.push(`bilibili hover #${index}: ${error.message.split("\n")[0]}`);
    }
    cards.push({
      id: `c${index + 1}`,
      href: record.href,
      bvid: record.bvid,
      baselineTitle: identityByBvid.get(record.bvid) ?? "",
      cardDomTitle: record.domTitle,
      candidates: record.candidates,
    });
  }
  PAGES.push({ site, kind: "home", url: "https://www.bilibili.com/", documentTitle, ogTitle, cards });
  await shot(page, "bilibili-home");
  await page.close();

  // 详情页 ×3：页级 resolvePageTitle 基线（与生产无锚点路径一致）。
  const detailHrefs = cards.filter((c) => c.href).slice(0, 3).map((c) => c.href);
  for (const [i, href] of detailHrefs.entries()) {
    const detail = await newPage(context, site);
    try {
      await detail.goto(href, { waitUntil: "domcontentloaded", timeout: 45000 });
      await dismissModal(detail, [".bili-mini-mask .bili-mini-close-button"]);
      await detail.waitForSelector("h1, video", { timeout: 25000 });
      await detail.waitForTimeout(2500);
      await inject(detail);
      const info = await detail.evaluate(() => ({
        documentTitle: document.title || "",
        ogTitle: document.querySelector('meta[property="og:title"]')?.content ?? "",
        h1: String(document.querySelector("h1")?.textContent ?? "").replace(/\s+/gu, " ").trim(),
        baselineTitle: globalThis.MacIDMMediaUtils.resolvePageTitle(document, null) || "",
        candidates: globalThis.MacIDMHarvest.harvestPage(document),
      }));
      PAGES.push({ site, kind: "detail", url: href, ...info });
      await shot(detail, `bilibili-detail-${i + 1}`);
    } catch (error) {
      ERRORS.push(`bilibili detail ${href}: ${error.message.split("\n")[0]}`);
      await shot(detail, "bilibili-detail-error");
    }
    await detail.close();
  }
}

// ---------- YouTube ----------

// watch 详情页：浏览器渲染优先；被出口 IP 风控（reCAPTCHA）拦截时，同一会话
// 直取 SSR HTML 用 setContent 提供真实 DOM。两条路径都跑生产 resolvePageTitle；
// 降级路径里 location 相关快路径不激活，证据由 note 字段标注。
async function captureYouTubeDetail(context, href, index) {
  const detail = await newPage(context, "youtube");
  try {
    await detail.goto(href, { waitUntil: "domcontentloaded", timeout: 45000 });
    await detail.waitForSelector("#movie_player, ytd-watch-flexy", { timeout: 20000 });
    await detail.waitForTimeout(3000);
    await inject(detail);
    const info = await detail.evaluate(() => ({
      documentTitle: document.title || "",
      ogTitle: document.querySelector('meta[property="og:title"]')?.content ?? "",
      h1: String(document.querySelector("h1")?.textContent ?? "").replace(/\s+/gu, " ").trim(),
      baselineTitle: globalThis.MacIDMMediaUtils.resolvePageTitle(document, null) || "",
      candidates: globalThis.MacIDMHarvest.harvestPage(document),
    }));
    PAGES.push({ site: "youtube", kind: "detail", url: href, ...info });
    await shot(detail, `youtube-detail-${index + 1}`);
  } catch {
    try {
      const response = await detail.context().request.get(href, {
        headers: { "accept-language": "zh-CN,zh;q=0.9,en;q=0.8" },
      });
      const html = await response.text();
      const hasOg = /<meta property="og:title" content="[^"]+"/.test(html);
      const blocked = html.length < 60000 || /unusual traffic|异常流量/i.test(html);
      if (!hasOg || blocked) {
        ERRORS.push(`youtube detail ${href}: watch page unavailable (captcha-blocked=${blocked}, og=${hasOg})`);
        return;
      }
      await detail.setContent(html, { waitUntil: "domcontentloaded", timeout: 60000 });
      await inject(detail);
      const info = await detail.evaluate(() => ({
        documentTitle: document.title || "",
        ogTitle: document.querySelector('meta[property="og:title"]')?.content ?? "",
        h1: String(document.querySelector("h1")?.textContent ?? "").replace(/\s+/gu, " ").trim(),
        baselineTitle: globalThis.MacIDMMediaUtils.resolvePageTitle(document, null) || "",
        candidates: globalThis.MacIDMHarvest.harvestPage(document),
      }));
      PAGES.push({
        site: "youtube", kind: "detail", url: href, ...info,
        note: "watch page captcha-blocked; evaluated on fetched SSR HTML, location fast-path inactive",
      });
      await shot(detail, `youtube-detail-${index + 1}-ssr`);
    } catch (fallbackError) {
      ERRORS.push(`youtube detail fallback ${href}: ${fallbackError.message.split("\n")[0]}`);
    }
  } finally {
    await detail.close();
  }
}

async function ytCardCount(page) {
  return page.evaluate(
    () => document.querySelectorAll("ytd-rich-item-renderer, yt-lockup-view-model").length,
  );
}

async function captureYouTube(context) {
  const site = "youtube";
  const page = await newPage(context, site);
  // 未登录新资料页的首页推荐流可能为空：先看几个视频养出历史，再回首页；
  // 仍为空则退回搜索结果页（同构卡片墙，报告注明替代面）。
  let surfaceURL = "https://www.youtube.com/";
  await page.goto(surfaceURL, { waitUntil: "domcontentloaded", timeout: 45000 });
  await dismissModal(page, [
    "ytd-consent-bump-v2 button[aria-label*='Accept all']",
    "tp-yt-paper-button[aria-label*='Accept']",
    "button:has-text('Accept all')",
    "button:has-text('全部接受')",
    "button:has-text('接受全部')",
  ]);
  if (await ytCardCount(page) === 0) {
    ERRORS.push("youtube home feed empty; seeding watch history via search results");
    await page.goto("https://www.youtube.com/results?search_query=" + encodeURIComponent("music"), {
      waitUntil: "domcontentloaded", timeout: 45000,
    });
    const watchHrefs = await page.evaluate(() => {
      const out = [];
      for (const a of document.querySelectorAll("a[href*='/watch']")) {
        const href = new URL(a.getAttribute("href"), location.origin).toString();
        if (/[\?&]v=/.test(href) && !out.includes(href)) out.push(href);
        if (out.length >= 3) break;
      }
      return out;
    });
    for (const href of watchHrefs.slice(0, 3)) {
      try {
        await page.goto(href, { waitUntil: "domcontentloaded", timeout: 45000 });
        await page.waitForTimeout(2500);
      } catch { /* 单个种子失败继续 */ }
    }
    await page.goto(surfaceURL, { waitUntil: "domcontentloaded", timeout: 45000 });
    await page.waitForTimeout(3000);
  }
  try {
    await page.waitForSelector("ytd-rich-item-renderer, yt-lockup-view-model", {
      timeout: 30000, state: "attached",
    });
  } catch (error) {
    // 首页仍为空：退回搜索结果页作为卡片墙。
    ERRORS.push("youtube home still empty; falling back to search results wall");
    surfaceURL = "https://www.youtube.com/results?search_query=" + encodeURIComponent("popular music videos");
    await page.goto(surfaceURL, { waitUntil: "domcontentloaded", timeout: 45000 });
    await page.waitForSelector("ytd-video-renderer, yt-lockup-view-model", {
      timeout: 30000, state: "attached",
    });
    await inject(page);
    await page.waitForTimeout(2500);
    const { documentTitle, ogTitle } = await meta(page);
    // 直接枚举结果页卡片；基线用卡片 DOM 标题（与预览桥同字符串，报告注明）。
    const records = await page.evaluate(() => {
      const out = [];
      for (const card of document.querySelectorAll("ytd-video-renderer, yt-lockup-view-model")) {
        const link = card.querySelector("a#video-title-link, a[href*='watch?v=']");
        const href = link ? new URL(link.getAttribute("href"), location.origin).toString() : "";
        if (!href || !/[\?&]v=/.test(href) || out.some((item) => item.href === href)) continue;
        const domTitle = String(card.querySelector("#video-title, h3, [class*='title']")?.textContent ?? "")
          .replace(/\s+/gu, " ").trim().slice(0, 200);
        out.push({ href, domTitle, candidates: globalThis.MacIDMHarvest.harvestCard(card) });
        if (out.length >= 5) break;
      }
      return out;
    });
    const cards = records.map((record, index) => ({
      id: `c${index + 1}`,
      href: record.href,
      baselineTitle: record.domTitle,
      cardDomTitle: record.domTitle,
      candidates: record.candidates,
    }));
    PAGES.push({
      site, kind: "list", url: surfaceURL, documentTitle, ogTitle, cards,
      note: "home feed empty; search-results wall; baseline=card DOM title (bridge-equivalent)",
    });
    await shot(page, "youtube-list-fallback");
    await page.close();
    if (cards.length === 0) throw error;
    const detailHrefs = cards.slice(0, 3).map((card) => card.href);
    for (const [i, href] of detailHrefs.entries()) {
      await captureYouTubeDetail(context, href, i);
    }
    return;
  }
  await inject(page);
  await page.waitForTimeout(2500);
  const { documentTitle, ogTitle } = await meta(page);

  const cards = [];
  const limit = 6;
  for (let index = 0; index < limit; index += 1) {
    const record = await page.evaluate(([index]) => {
      const card = document.querySelectorAll("ytd-rich-item-renderer, yt-lockup-view-model")[index];
      if (!card) return null;
      const link = card.querySelector("a#video-title-link, a[href*='watch?v=']");
      const href = link ? new URL(link.getAttribute("href"), location.origin).toString() : "";
      const domTitle = String(
        card.querySelector("#video-title")?.textContent
          ?? card.querySelector("[class*='metadata'] [class*='title'], h3")?.textContent
          ?? "",
      ).replace(/\s+/gu, " ").trim().slice(0, 200);
      return { href, domTitle, candidates: globalThis.MacIDMHarvest.harvestCard(card) };
    }, [index]);
    if (!record?.href) continue;
    // 悬停出浮层预览播放器；基线读取与生产桥同源（getVideoData）。
    let baseline = "";
    try {
      const cover = page.locator("ytd-rich-item-renderer, yt-lockup-view-model").nth(index)
        .locator("a#thumbnail, a[href*='/watch']").first();
      await cover.scrollIntoViewIfNeeded();
      await cover.hover({ timeout: 5000 });
      await page.waitForTimeout(3000);
      baseline = await page.evaluate(() => {
        const host = document.querySelector("ytd-video-preview");
        const player = host?.querySelector("#inline-preview-player")
          ?? host?.querySelector(".html5-video-player");
        const data = player?.getVideoData?.();
        if (!data || !/^[A-Za-z0-9_-]{5,}$/.test(String(data.video_id ?? ""))) return "";
        return String(data.title ?? "").slice(0, 200);
      });
    } catch (error) {
      ERRORS.push(`youtube hover #${index}: ${error.message.split("\n")[0]}`);
    }
    cards.push({
      id: `c${index + 1}`,
      href: record.href,
      baselineTitle: baseline,
      cardDomTitle: record.domTitle,
      candidates: record.candidates,
    });
  }
  PAGES.push({ site, kind: "home", url: "https://www.youtube.com/", documentTitle, ogTitle, cards });
  await shot(page, "youtube-home");

  const detailHrefs = cards.filter((c) => c.href).slice(0, 3).map((c) => c.href);
  for (const [i, href] of detailHrefs.entries()) {
    await captureYouTubeDetail(context, href, i);
  }
}

// ---------- 抖音 ----------

async function captureDouyin(context) {
  const site = "douyin";
  const page = await newPage(context, site);
  // feed XHR 里的 aweme_id+desc：详情页直达 URL 的来源（卡片无 href）。
  const awemeItems = [];
  page.on("response", (response) => {
    try {
      if (!/aweme\/v1\//.test(response.url())) return;
      const type = String(response.headers()["content-type"] ?? "");
      if (!type.includes("json")) return;
      response.json().then((body) => {
        const walk = (node) => {
          if (!node || typeof node !== "object") return;
          if (Array.isArray(node)) { node.forEach(walk); return; }
          const id = typeof node.aweme_id === "string" ? node.aweme_id : "";
          const desc = typeof node.desc === "string" ? node.desc.trim() : "";
          if (id && desc && !awemeItems.some((item) => item.id === id)) {
            awemeItems.push({ id, desc: desc.slice(0, 200) });
          }
          for (const value of Object.values(node)) walk(value);
        };
        walk(body);
      }).catch(() => {});
    } catch { /* 忽略 */ }
  });
  await page.goto("https://www.douyin.com/jingxuan", { waitUntil: "domcontentloaded", timeout: 60000 });
  await page.waitForTimeout(6000);
  await dismissModal(page, [
    "[data-e2e='login-close']",
    "#login-pannel [aria-label='关闭']",
    "button[aria-label='关闭']",
    "[class*='login'] [class*='close' i]",
  ]);
  await page.waitForSelector(".jingxuanVideoCard, [class*='waterfall-videoCardContainer']", { timeout: 30000 });
  await inject(page);
  await page.waitForTimeout(3000);
  // 登录弹窗挡住卡片点击：定位登录面板移除，并清掉高位 fixed 遮挡层。
  const removedNodes = await page.evaluate(() => {
    let removed = 0;
    const panel = document.querySelector("#login-pannel, [id*='login-pannel'], [class*='login-panel' i]");
    if (panel) { panel.remove(); removed += 1; }
    else {
      let best = null;
      for (const el of document.querySelectorAll("div")) {
        if (/扫码登录|验证码登录/.test(el.textContent || "")
          && (!best || el.textContent.length < best.textContent.length)) best = el;
      }
      if (best) { best.remove(); removed += 1; }
    }
    for (const el of [...document.querySelectorAll("div, div ~ *")]) {
      const style = globalThis.getComputedStyle(el);
      if (style.position === "fixed" && Number(style.zIndex) > 50
        && !el.querySelector("video") && (el.textContent || "").length < 60) {
        el.remove(); removed += 1;
      }
    }
    document.documentElement.style.overflow = "auto";
    document.body.style.overflow = "auto";
    return removed;
  });
  ERRORS.push(`douyin modal removal: ${removedNodes} nodes`);
  await page.waitForTimeout(1500);
  const { documentTitle, ogTitle } = await meta(page);

  // feed 数据内嵌于 SSR（self.__pace_f）而非 XHR：从 script 文本提取 aweme_id。
  const ssrIds = await page.evaluate(() => {
    const text = [...document.querySelectorAll("script")]
      .map((script) => script.textContent ?? "").join("").replace(/\\/gu, "");
    const ids = [];
    const pattern = /aweme_id"?\s*:\s*"(\d{10,32})/gu;
    let match;
    while ((match = pattern.exec(text)) !== null) {
      if (!ids.includes(match[1])) ids.push(match[1]);
      if (ids.length >= 8) break;
    }
    return ids;
  });
  for (const id of ssrIds) {
    if (!awemeItems.some((item) => item.id === id)) awemeItems.push({ id, desc: "" });
  }
  ERRORS.push(`douyin aweme ids: xhr+ssr=${awemeItems.length} (ssr=${ssrIds.length})`);

  const cards = [];
  const limit = 6;
  for (let index = 0; index < limit; index += 1) {
    const record = await page.evaluate(([index]) => {
      const card = document.querySelectorAll(".jingxuanVideoCard, [class*='waterfall-videoCardContainer']")[index];
      if (!card) return null;
      const link = card.querySelector("a[href*='/video/'], a[href*='modal_id']");
      const href = link ? new URL(link.getAttribute("href"), location.origin).toString() : "";
      const domTitle = String(
        card.querySelector('[data-feed-ad-click-refer="title"]')?.textContent
          ?? card.querySelector("img.discover-video-card-img")?.getAttribute("alt")
          ?? "",
      ).replace(/\s+/gu, " ").trim().slice(0, 200);
      return { href, domTitle, candidates: globalThis.MacIDMHarvest.harvestCard(card) };
    }, [index]);
    if (!record) continue;
    // 基线：生产 douyinContentTitle 卡片快路径（经 resolvePageTitle 入口）。
    let baseline = "";
    try {
      baseline = await page.evaluate(([index]) => {
        const card = document.querySelectorAll(
          ".jingxuanVideoCard, [class*='waterfall-videoCardContainer']",
        )[index];
        const video = card?.querySelector("video") ?? card;
        return globalThis.MacIDMMediaUtils.resolvePageTitle(document, video) || "";
      }, [index]);
    } catch (error) {
      ERRORS.push(`douyin baseline #${index}: ${error.message.split("\n")[0]}`);
    }
    cards.push({
      id: `c${index + 1}`,
      href: record.href,
      baselineTitle: baseline,
      cardDomTitle: record.domTitle,
      candidates: record.candidates,
    });
  }
  PAGES.push({ site, kind: "home", url: "https://www.douyin.com/jingxuan", documentTitle, ogTitle, cards });
  await shot(page, "douyin-home");

  // 详情 ×3：优先用 feed XHR 提取的 aweme_id 直达 /video/<id>；不足时退回点击流程。
  const detailTargets = awemeItems.slice(0, 3);
  for (const [i, item] of detailTargets.entries()) {
    const detail = await newPage(context, site);
    try {
      await detail.goto(`https://www.douyin.com/video/${item.id}`, {
        waitUntil: "domcontentloaded", timeout: 60000,
      });
      await detail.waitForSelector("video", { timeout: 25000 });
      await detail.waitForTimeout(4000);
      await inject(detail);
      const info = await detail.evaluate(DOUYIN_DETAIL_EVAL_SOURCE);
      PAGES.push({ site, kind: "detail", url: detail.url(), ...info });
      await shot(detail, `douyin-detail-${i + 1}`);
    } catch (error) {
      ERRORS.push(`douyin detail video/${item.id}: ${error.message.split("\n")[0]}`);
      await shot(detail, "douyin-detail-error");
    }
    await detail.close();
  }
  const detailCaptured = PAGES.filter((p) => p.site === site && p.kind === "detail").length;
  if (detailCaptured < 3) {
    ERRORS.push(`douyin details via URL: ${detailCaptured}/3; falling back to card clicks`);
  }

  // 兜底：URL 路线不足 3 个时回到 feed 内点击卡片开 modal 的旧路径。
  if (detailCaptured >= 3 || cards.length === 0) {
    await page.close();
    return;
  }
  const detailCount = Math.min(3, cards.length);
  for (let i = 0; i < detailCount; i += 1) {
    let spawned = null;
    try {
      const cardLoc = page.locator(".jingxuanVideoCard, [class*='waterfall-videoCardContainer']").nth(i);
      await cardLoc.scrollIntoViewIfNeeded();
      const spawnedPromise = context.waitForEvent("page", { timeout: 10000 }).catch(() => null);
      await cardLoc.click({ timeout: 8000 });
      spawned = await spawnedPromise;
      const target = spawned ?? page;
      if (!spawned) {
        await page.waitForURL(/modal_id|\/video\//, { timeout: 15000 }).catch(() => {});
      }
      await target.waitForTimeout(5000);
      await target.evaluate(mediaUtilsSource);
      await target.evaluate(HARVEST_SOURCE);
      const info = await target.evaluate(DOUYIN_DETAIL_EVAL_SOURCE);
      PAGES.push({ site, kind: "detail", url: target.url(), ...info });
      await shot(target, `douyin-detail-${i + 1}`);
      if (spawned) {
        await spawned.close();
      } else {
        await page.keyboard.press("Escape");
        await page.waitForTimeout(2000);
        if (!/jingxuan/.test(page.url())) {
          await page.goBack({ timeout: 20000 }).catch(() => {});
        }
        await page.waitForTimeout(2500);
        await inject(page);
      }
    } catch (error) {
      ERRORS.push(`douyin detail #${i}: ${error.message.split("\n")[0]}`);
      await shot(page, "douyin-detail-error");
      if (spawned) await spawned.close().catch(() => {});
    }
  }
  await page.close();
}

// ---------- main ----------

async function main() {
  mkdirSync(OUT_DIR, { recursive: true });
  const executablePath = findChromiumExecutable();
  const proxyServer = process.env.https_proxy ?? process.env.HTTPS_PROXY
    ?? process.env.http_proxy ?? process.env.HTTP_PROXY ?? null;
  const browser = await chromium.launch({
    executablePath,
    headless: true,
    // 本机经 Clash 等本地代理出网；不配置则境外站直连超时。
    proxy: proxyServer ? { server: proxyServer } : undefined,
    args: ["--disable-blink-features=AutomationControlled", "--lang=zh-CN"],
  });
  const context = await browser.newContext({
    locale: "zh-CN",
    timezoneId: "Asia/Shanghai",
    viewport: { width: 1440, height: 900 },
    userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
  });
  await context.addInitScript(() => {
    Object.defineProperty(navigator, "webdriver", { get: () => undefined });
  });

  await context.addInitScript(() => {
    // 抖音登录弹窗会被周期性重新注入：在文档起点挂持续清除器。
    // 仅作用于 douyin 域，避免误伤其他站点的浮层。
    const sweep = () => {
      if (!/douyin\.com$/.test(location.hostname)) return;
      let best = null;
      for (const el of document.querySelectorAll("div")) {
        const text = el.textContent || "";
        if (/扫码登录|验证码登录/.test(text)
          && el.querySelectorAll("div").length < 80
          && (!best || text.length < best.textContent.length)) best = el;
      }
      if (best) (best.closest("[id*='login' i], [class*='login' i]") ?? best).remove();
      for (const el of document.querySelectorAll("div")) {
        const style = getComputedStyle(el);
        if (style.position === "fixed" && Number(style.zIndex) > 50
          && !el.querySelector("video") && (el.textContent || "").length < 60) el.remove();
      }
      document.body.style.overflow = "auto";
    };
    const observer = new MutationObserver(() => { try { sweep(); } catch { /* 忽略 */ } });
    const start = () => observer.observe(document.body ?? document.documentElement, {
      childList: true, subtree: true,
    });
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", start);
    } else {
      start();
    }
  });

  for (const [name, capture] of [
    ["bilibili", captureBilibili],
    ["youtube", captureYouTube],
    ["douyin", captureDouyin],
  ]) {
    const startedAt = Date.now();
    try {
      await capture(context);
      console.log(`[ok] ${name}: ${PAGES.filter((p) => p.site === name).length} pages in ${Date.now() - startedAt}ms`);
    } catch (error) {
      ERRORS.push(`${name} capture failed: ${error.message.split("\n")[0]}`);
      console.error(`[fail] ${name}: ${error.message.split("\n")[0]}`);
    }
  }

  await browser.close();
  const outFile = join(OUT_DIR, "pages.json");
  writeFileSync(outFile, JSON.stringify({ capturedAt: new Date().toISOString(), errors: ERRORS, pages: PAGES }, null, 2));
  console.log(`pages: ${PAGES.length} -> ${outFile}`);
  if (ERRORS.length) console.log(`errors (${ERRORS.length}):\n  ${ERRORS.join("\n  ")}`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
