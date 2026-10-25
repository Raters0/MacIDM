// Jev 标题评测（已登录会话）· ego-browser 抓取。
//
// 用法（每轮一个站点，同一 TaskSpace 跨轮复用；脚本经 stdin 交给
// `ego-browser nodejs`。ego 的 node 进程环境被清洗，环境变量不可用，
// 改用 /tmp 轮次文件传参）：
//   写 /tmp/macidm-jev-eval/ego-round.json = {"site":"bilibili"}
//   ego-browser nodejs < Tests/Support/jev-title-eval/ego-capture.mjs
//   下一轮把 spaceId 写回该文件再换 site。
// 与 capture-pages.mjs（未登录 playwright 版）产出同一 schema：
// 每页注入生产 media-utils.js 跑基线、用零站点知识收割器收候选；
// 输出 /tmp/macidm-jev-eval/pages-logged-in/${site}.json，评测前合并。
// 证据只落该目录，不进版本库；不触碰用户已有标签页。

import { readFile, writeFile, mkdir } from "node:fs/promises";
import { join } from "node:path";

const ROUND_FILE = "/tmp/macidm-jev-eval/ego-round.json";
const OUT_DIR = "/tmp/macidm-jev-eval/pages-logged-in";
const round = JSON.parse(await readFile(ROUND_FILE, "utf8"));
const REPO_ROOT = round.repoRoot ?? "/Users/riley/Desktop/AI_workspace/MacIDM";
const SITE = round.site ?? "";
if (!["bilibili", "youtube", "douyin"].includes(SITE)) {
  console.error("ego-round.json must carry {\"site\":\"bilibili|youtube|douyin\"}");
  process.exit(1);
}

const mediaUtilsSource = await readFile(
  join(REPO_ROOT, "BrowserExtension/chrome/src/shared/media-utils.js"), "utf8");
const harvestSource = await readFile(
  join(REPO_ROOT, "Tests/Support/jev-title-eval/generic-harvester.js"), "utf8");
const douyinDetailEval = await readFile(
  join(REPO_ROOT, "Tests/Support/jev-title-eval/douyin-detail-eval.js"), "utf8");

await mkdir(join(OUT_DIR, "shots"), { recursive: true });
const spaceId = round.spaceId ? Number(round.spaceId) : null;
const task = spaceId ? await taskSpace(spaceId) : await taskSpace("jev logged-in title capture");
console.log("spaceId:", task.spaceId);
const page = task.page("p1");

const ERRORS = [];
const PAGES = [];

const META_EVAL = `(() => ({
  documentTitle: document.title || "",
  ogTitle: document.querySelector('meta[property="og:title"]')?.content ?? "",
}))()`;

async function inject() {
  await page.evaluate(mediaUtilsSource);
  await page.evaluate(harvestSource);
}

async function shot(name) {
  try {
    await page.screenshot({ path: join(OUT_DIR, "shots", `${name}.png`) });
  } catch { /* 截图失败不影响抓取 */ }
}

// ---------- Bilibili ----------

async function captureBilibili() {
  await page.goto("https://www.bilibili.com/", { waitUntil: "domcontentloaded", timeout: 45000 });
  await page.waitForSelector(".bili-video-card", { timeout: 30000, state: "attached" });
  await page.waitForTimeout(2500);
  await inject();
  const meta = await page.evaluate(META_EVAL);
  const identityByBvid = new Map();
  const cards = [];
  const count = await page.evaluate(() => document.querySelectorAll(".bili-video-card").length);
  for (let index = 0; index < Math.min(count, 6); index += 1) {
    const record = await page.evaluate((i) => {
      const card = document.querySelectorAll(".bili-video-card")[i];
      if (!card) return null;
      const link = card.querySelector("a[href*='/video/']");
      const href = link ? new URL(link.getAttribute("href"), location.origin).toString() : "";
      const bvid = (href.match(/\/video\/(BV[0-9A-Za-z]+)/) ?? [])[1] ?? "";
      return { href, bvid, candidates: globalThis.MacIDMHarvest.harvestCard(card) };
    }, index);
    if (!record?.href) continue;
    try {
      await page.hover(`css=.bili-video-card >> nth=${index}`, {
        timeout: 5000, label: "悬停卡片出预览",
      });
      await page.waitForTimeout(2600);
      const identities = await page.evaluate(
        () => globalThis.MacIDMMediaUtils.collectBilibiliPreviewIdentities(document, location.href),
      );
      for (const identity of identities) identityByBvid.set(identity.bvid, identity.title);
    } catch (error) {
      ERRORS.push(`bili hover #${index}: ${String(error).split("\n")[0].slice(0, 120)}`);
    }
    cards.push({
      id: `c${cards.length + 1}`,
      href: record.href,
      bvid: record.bvid,
      baselineTitle: identityByBvid.get(record.bvid) ?? "",
      candidates: record.candidates,
    });
  }
  PAGES.push({ site: "bilibili", kind: "home", url: "https://www.bilibili.com/", ...meta, cards });
  await shot("bili-home");

  for (const href of cards.filter((c) => c.href).slice(0, 3).map((c) => c.href)) {
    try {
      await page.goto(href, { waitUntil: "domcontentloaded", timeout: 45000 });
      await page.waitForSelector("h1, video", { timeout: 25000, state: "attached" });
      await page.waitForTimeout(2500);
      await inject();
      const info = await page.evaluate(() => ({
        documentTitle: document.title || "",
        ogTitle: document.querySelector('meta[property="og:title"]')?.content ?? "",
        h1: String(document.querySelector("h1")?.textContent ?? "").replace(/\s+/gu, " ").trim(),
        baselineTitle: globalThis.MacIDMMediaUtils.resolvePageTitle(document, null) || "",
        candidates: globalThis.MacIDMHarvest.harvestPage(document),
      }));
      PAGES.push({ site: "bilibili", kind: "detail", url: href, ...info });
      await shot(`bili-detail-${PAGES.filter((p) => p.kind === "detail").length}`);
    } catch (error) {
      ERRORS.push(`bili detail ${href}: ${String(error).split("\n")[0].slice(0, 120)}`);
    }
  }
}

// ---------- YouTube ----------

async function captureYouTube() {
  await page.goto("https://www.youtube.com/", { waitUntil: "domcontentloaded", timeout: 45000 });
  await page.waitForSelector("ytd-rich-item-renderer, yt-lockup-view-model", {
    timeout: 30000, state: "attached",
  });
  await page.waitForTimeout(2500);
  await inject();
  const meta = await page.evaluate(META_EVAL);
  const cards = [];
  for (let index = 0; index < 6; index += 1) {
    const record = await page.evaluate((i) => {
      const card = document.querySelectorAll("ytd-rich-item-renderer, yt-lockup-view-model")[i];
      if (!card) return null;
      const link = card.querySelector("a#video-title-link, a[href*='watch?v=']");
      const href = link ? new URL(link.getAttribute("href"), location.origin).toString() : "";
      if (!href || !/[\?&]v=/.test(href)) return null;
      const domTitle = String(
        card.querySelector("#video-title")?.textContent
          ?? card.querySelector("[class*='metadata'] [class*='title'], h3")?.textContent
          ?? "",
      ).replace(/\s+/gu, " ").trim().slice(0, 200);
      return { href, domTitle, candidates: globalThis.MacIDMHarvest.harvestCard(card) };
    }, index);
    if (!record) continue;
    let baseline = "";
    try {
      await page.hover(`css=ytd-rich-item-renderer, yt-lockup-view-model >> nth=${index}`, {
        timeout: 5000, label: "悬停卡片出预览",
      });
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
      ERRORS.push(`yt hover #${index}: ${String(error).split("\n")[0].slice(0, 120)}`);
    }
    cards.push({
      id: `c${cards.length + 1}`,
      href: record.href,
      baselineTitle: baseline || record.domTitle,
      baselineFromBridge: Boolean(baseline),
      cardDomTitle: record.domTitle,
      candidates: record.candidates,
    });
  }
  PAGES.push({
    site: "youtube", kind: "home", url: "https://www.youtube.com/", ...meta, cards,
    note: "logged-in home feed; baseline=preview bridge read where available, else card DOM title",
  });
  await shot("yt-home");

  for (const [i, href] of cards.filter((c) => c.href).slice(0, 3).map((c) => c.href).entries()) {
    try {
      await page.goto(href, { waitUntil: "domcontentloaded", timeout: 45000 });
      await page.waitForSelector("#movie_player, ytd-watch-flexy", { timeout: 25000, state: "attached" });
      await page.waitForTimeout(3000);
      await inject();
      const info = await page.evaluate(() => ({
        documentTitle: document.title || "",
        ogTitle: document.querySelector('meta[property="og:title"]')?.content ?? "",
        h1: String(document.querySelector("h1")?.textContent ?? "").replace(/\s+/gu, " ").trim(),
        baselineTitle: globalThis.MacIDMMediaUtils.resolvePageTitle(document, null) || "",
        candidates: globalThis.MacIDMHarvest.harvestPage(document),
      }));
      PAGES.push({ site: "youtube", kind: "detail", url: href, ...info });
      await shot(`yt-detail-${i + 1}`);
    } catch (error) {
      ERRORS.push(`yt detail ${href}: ${String(error).split("\n")[0].slice(0, 120)}`);
    }
  }
}

// ---------- 抖音 ----------

async function captureDouyin() {
  await page.goto("https://www.douyin.com/jingxuan", { waitUntil: "domcontentloaded", timeout: 60000 });
  await page.waitForSelector(".jingxuanVideoCard, [class*='waterfall-videoCardContainer']", {
    timeout: 30000, state: "attached",
  });
  await page.waitForTimeout(3000);
  await inject();
  const meta = await page.evaluate(META_EVAL);

  // feed 数据内嵌 SSR：从 script 文本提取 aweme_id 作详情页直达 URL。
  const awemeIds = await page.evaluate(() => {
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
  console.log("aweme ids from SSR:", awemeIds.length);

  const cards = [];
  for (let index = 0; index < 6; index += 1) {
    const record = await page.evaluate((i) => {
      const card = document.querySelectorAll(
        ".jingxuanVideoCard, [class*='waterfall-videoCardContainer']",
      )[i];
      if (!card) return null;
      const link = card.querySelector("a[href*='/video/'], a[href*='modal_id']");
      const href = link ? new URL(link.getAttribute("href"), location.origin).toString() : "";
      const domTitle = String(
        card.querySelector('[data-feed-ad-click-refer="title"]')?.textContent
          ?? card.querySelector("img.discover-video-card-img")?.getAttribute("alt")
          ?? "",
      ).replace(/\s+/gu, " ").trim().slice(0, 200);
      return { href, domTitle, candidates: globalThis.MacIDMHarvest.harvestCard(card) };
    }, index);
    if (!record) continue;
    let baseline = "";
    try {
      baseline = await page.evaluate((i) => {
        const card = document.querySelectorAll(
          ".jingxuanVideoCard, [class*='waterfall-videoCardContainer']",
        )[i];
        const video = card?.querySelector("video") ?? card;
        return globalThis.MacIDMMediaUtils.resolvePageTitle(document, video) || "";
      }, index);
    } catch (error) {
      ERRORS.push(`dy baseline #${index}: ${String(error).split("\n")[0].slice(0, 120)}`);
    }
    cards.push({
      id: `c${cards.length + 1}`,
      href: record.href,
      baselineTitle: baseline,
      cardDomTitle: record.domTitle,
      candidates: record.candidates,
    });
  }
  PAGES.push({ site: "douyin", kind: "home", url: "https://www.douyin.com/jingxuan", ...meta, cards });
  await shot("dy-home");

  const detailTargets = (awemeIds.length >= 3 ? awemeIds.slice(0, 3) : []).map((id) => ({
    url: `https://www.douyin.com/video/${id}`,
  }));
  for (const [i, target] of detailTargets.entries()) {
    try {
      await page.goto(target.url, { waitUntil: "domcontentloaded", timeout: 60000 });
      await page.waitForSelector("video", { timeout: 25000, state: "attached" });
      await page.waitForTimeout(4000);
      await inject();
      const info = await page.evaluate(douyinDetailEval);
      PAGES.push({ site: "douyin", kind: "detail", url: page.url(), ...info });
      await shot(`dy-detail-${i + 1}`);
    } catch (error) {
      ERRORS.push(`dy detail ${target.url}: ${String(error).split("\n")[0].slice(0, 120)}`);
    }
  }
  // SSR 无 aweme_id 时兜底：每轮重进 feed 后点击第 i 张卡开 modal，评估后返回。
  let viaClick = 0;
  for (let i = 0; PAGES.filter((p) => p.kind === "detail").length + viaClick < 3 && i < 6; i += 1) {
    try {
      await page.goto("https://www.douyin.com/jingxuan", { waitUntil: "domcontentloaded", timeout: 60000 });
      await page.waitForSelector(".jingxuanVideoCard, [class*='waterfall-videoCardContainer']", {
        timeout: 30000, state: "attached",
      });
      await page.waitForTimeout(3000);
      await inject();
      await page.click(`css=.jingxuanVideoCard, [class*='waterfall-videoCardContainer'] >> nth=${i}`, {
        timeout: 8000, label: "点击卡片开详情",
      });
      await page.waitForURL(/modal_id|\/video\//, { timeout: 15000 }).catch(() => {});
      await page.waitForTimeout(5000);
      await inject();
      const info = await page.evaluate(douyinDetailEval);
      const detailURL = String(await page.url());
      if (!info.baselineTitle || /抖音精选电脑版/.test(info.baselineTitle)) {
        ERRORS.push(`dy click #${i}: baseline fell back to brand (${detailURL.slice(0, 60)})`);
      }
      PAGES.push({ site: "douyin", kind: "detail", url: detailURL, viaClick: true, ...info });
      await shot(`dy-detail-click-${viaClick + 1}`);
      viaClick += 1;
    } catch (error) {
      ERRORS.push(`dy click #${i}: ${String(error).split("\n")[0].slice(0, 120)}`);
    }
  }
  const captured = PAGES.filter((p) => p.kind === "detail").length;
  console.log("douyin details via URL:", captured - viaClick, "| via click:", viaClick);
}

for (const [name, capture] of [
  ["bilibili", captureBilibili],
  ["youtube", captureYouTube],
  ["douyin", captureDouyin],
]) {
  if (name !== SITE) continue;
  const startedAt = Date.now();
  try {
    await capture();
    console.log(`[ok] ${name}: ${PAGES.length} pages in ${Date.now() - startedAt}ms`);
  } catch (error) {
    ERRORS.push(`${name} capture failed: ${String(error).split("\n")[0].slice(0, 160)}`);
    console.error(`[fail] ${name}: ${String(error).split("\n")[0].slice(0, 160)}`);
    await shot(`${name}-error`);
  }
}

await writeFile(
  join(OUT_DIR, `${SITE}.json`),
  JSON.stringify({ errors: ERRORS, pages: PAGES }, null, 2),
);
console.log(`wrote ${PAGES.length} pages -> ${join(OUT_DIR, `${SITE}.json`)}`);
if (ERRORS.length) console.log(`errors (${ERRORS.length}):\n  ${ERRORS.join("\n  ")}`);
