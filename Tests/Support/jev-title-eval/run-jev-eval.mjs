// Jev 标题评测 · 阶段 2：调用 TypeSafe Jev 并与我们的规则对比。
//
// 输入：capture-pages.mjs 产出的 pages.json。
// 设计（对应 typesafe-ai skill 的 pre-parsed value extraction 模式）：
// - state 只装页面级上下文（URL/文档标题/og:title）与每卡候选字符串，
//   不投喂整页 DOM；候选由零站点知识的通用收割器产出（见 capture 脚本）。
// - 每卡一个 choice 问题：criteria 的 key 是候选 id，value 是候选文本；
//   附 `none` 选项（候选里没有视频标题时选它）。
// - 每个页面一个请求：state 摄取一次，页内所有卡片问题并行评估。
//
// 用法：TYPESAFE_API_KEY=... node run-jev-eval.mjs <pagesDir> <outDir>
// 密钥只从环境变量读取，绝不写入本仓库或输出文件。

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";

const PAGES_DIR = process.argv[2] ?? ".";
const OUT_DIR = process.argv[3] ?? PAGES_DIR;
const API_URL = "https://api.typesafe.ai/v1/systemone";
const MODEL = "jev-latest";

const API_KEY = process.env.TYPESAFE_API_KEY ?? "";
if (!API_KEY) {
  console.error("missing TYPESAFE_API_KEY env");
  process.exit(1);
}

const pages = JSON.parse(readFileSync(join(PAGES_DIR, "pages.json"), "utf8"));

// ---------- 归一化（对比用；与生产 stripBrandSuffix 同思路，独立实现避免依赖 DOM） ----------

function normalizeTitle(value) {
  return String(value ?? "")
    .replace(/\s+/gu, " ")
    .trim()
    .replace(/\s*[_\-|]\s*(哔哩哔哩[^_\-|]*|bilibili)[_\-|]?/giu, "")
    .replace(/\s*-\s*YouTube\s*$/iu, "")
    .replace(/\s*[-|]\s*抖音(精选电脑版)?\s*$/u, "")
    .replace(/\s*[-|]\s*抖音(精选电脑版)?\s/gu, " ")
    .trim()
    .toLowerCase();
}

function titlesMatch(a, b) {
  const na = normalizeTitle(a);
  const nb = normalizeTitle(b);
  if (!na || !nb) return false;
  if (na === nb) return true;
  // 抖音 caption 常在 200 字符处截断：允许一方为另一方的前缀（≥12 字符）。
  if (na.length >= 12 && nb.startsWith(na)) return true;
  if (nb.length >= 12 && na.startsWith(nb)) return true;
  return false;
}

// ---------- state/questions 构建 ----------

function candidateId(cardId, index) {
  return `k${index + 1}`;
}

function buildHomePageRequest(page) {
  const state = {
    page: {
      url: page.url,
      documentTitle: page.documentTitle ?? "",
      ogTitle: page.ogTitle ?? "",
    },
    cards: (page.cards ?? []).map((card) => ({
      id: card.id,
      link: card.href ?? "",
      candidates: (card.candidates ?? []).map((candidate, index) => ({
        id: candidateId(card.id, index),
        text: candidate.text,
        source: candidate.source,
      })),
    })),
  };
  const questions = {};
  for (const card of state.cards) {
    if (card.candidates.length === 0) continue;
    const criteria = {};
    for (const candidate of card.candidates) criteria[candidate.id] = candidate.text;
    criteria.none = null;
    questions[`card_${card.id}`] = {
      type: "choice",
      instructions: "Each entry of `cards` in the state is one video card from a single webpage, and `page` describes that page. This question concerns the card whose `id` matches the question name (card_<id>). Decide which candidate string is the title of that card's own video — the name a person would naturally use for the video file. Judge only by the card's own content; the page or site name and any slogan are never a video title. The criteria keys are the candidate ids and the criteria values are the candidate texts; pick exactly one candidate id. Pick `none` only when no candidate is that card's video title.",
      criteria,
    };
  }
  return { state, questions };
}

function buildDetailPageRequest(page) {
  const state = {
    page: {
      url: page.url,
      documentTitle: page.documentTitle ?? "",
      ogTitle: page.ogTitle ?? "",
      h1: page.h1 ?? "",
    },
  };
  const questions = {};
  const candidates = page.candidates ?? [];
  if (candidates.length > 0) {
    const criteria = {};
    candidates.forEach((candidate, index) => {
      criteria[candidateId("p", index)] = candidate.text;
    });
    criteria.none = null;
    questions.page_title = {
      type: "choice",
      instructions: "The state's `page` describes one video watch page. Decide which candidate string is the title of the video playing on this page — the name a person would naturally use for the video file. The site or platform name and any slogan are never a video title. The criteria keys are the candidate ids and the criteria values are the candidate texts; pick exactly one candidate id. Pick `none` only when no candidate is the video's title.",
      criteria,
    };
  }
  return { state, questions };
}

// ---------- API 调用 ----------

async function callJev(request, label) {
  const body = JSON.stringify({ model: MODEL, state: request.state, questions: request.questions });
  for (let attempt = 1; attempt <= 4; attempt += 1) {
    const response = await fetch(API_URL, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${API_KEY}`,
        "Content-Type": "application/json",
      },
      body,
    });
    if (response.ok) return response.json();
    const text = await response.text().catch(() => "");
    if (response.status === 429 || response.status === 529) {
      const waitMs = attempt * 4000;
      console.log(`  [retry] ${label}: ${response.status}, wait ${waitMs}ms`);
      await new Promise((resolve) => setTimeout(resolve, waitMs));
      continue;
    }
    throw new Error(`${label}: HTTP ${response.status}: ${text.slice(0, 300)}`);
  }
  throw new Error(`${label}: retries exhausted`);
}

// ---------- 逐页评估 ----------

const rows = [];
const rawResponses = [];

for (const page of pages.pages) {
  const isCardPage = Array.isArray(page.cards) && page.cards.length > 0;
  const request = isCardPage ? buildHomePageRequest(page) : buildDetailPageRequest(page);
  if (Object.keys(request.questions).length === 0) {
    console.log(`[skip] ${page.site}/${page.kind}: no questions`);
    continue;
  }
  const label = `${page.site}/${page.kind}`;
  let result;
  try {
    result = await callJev(request, label);
  } catch (error) {
    console.error(`[fail] ${error.message}`);
    rows.push({ site: page.site, kind: page.kind, error: error.message });
    continue;
  }
  rawResponses.push({ label, model: result.model, usage: result.usage });
  console.log(`[ok] ${label}: in=${result.usage?.input_tokens} out=${result.usage?.output_tokens}`);

  if (isCardPage) {
    for (const card of page.cards) {
      const answer = result.answers?.[`card_${card.id}`];
      const candidates = card.candidates ?? [];
      const jevId = answer?.choice ?? "";
      const jevText = candidates.find((_, index) => candidateId(card.id, index) === jevId)?.text ?? "";
      const isNone = jevId === "none";
      const hasBaseline = Boolean(card.baselineTitle);
      const baselineIsBrandLike = card.baselineTitle === page.documentTitle;
      const match = hasBaseline && !isNone && titlesMatch(jevText, card.baselineTitle);
      rows.push({
        site: page.site,
        kind: page.kind,
        itemId: card.id,
        baseline: card.baselineTitle,
        cardDomTitle: card.cardDomTitle ?? "",
        jevChoice: jevText || "(none)",
        jevIsNone: isNone,
        confidence: answer?.confidence ?? null,
        topProbability: isNone ? null : answer?.probabilities?.[jevId] ?? null,
        match,
        note: !hasBaseline ? "no-baseline" : baselineIsBrandLike ? "baseline-is-page-brand" : "",
      });
    }
  } else {
    const answer = result.answers?.page_title;
    const candidates = page.candidates ?? [];
    const jevId = answer?.choice ?? "";
    const jevText = candidates.find((_, index) => candidateId("p", index) === jevId)?.text ?? "";
    const isNone = jevId === "none";
    const hasBaseline = Boolean(page.baselineTitle);
    const baselineIsBrandLike = page.baselineTitle === page.documentTitle
      || /抖音精选电脑版|哔哩哔哩[^_]*bilibili|- YouTube$/iu.test(page.baselineTitle);
    const match = hasBaseline && !isNone && titlesMatch(jevText, page.baselineTitle);
    const noneIsRight = isNone && baselineIsBrandLike;
    rows.push({
      site: page.site,
      kind: page.kind,
      url: page.url,
      baseline: page.baselineTitle,
      jevChoice: jevText || "(none)",
      jevIsNone: isNone,
      confidence: answer?.confidence ?? null,
      topProbability: isNone ? null : answer?.probabilities?.[jevId] ?? null,
      match,
      note: !hasBaseline ? "no-baseline" : baselineIsBrandLike ? "baseline-is-page-brand (none would be right)" : "",
      noneCountsAsMatch: noneIsRight,
    });
  }
}

// ---------- 汇总 ----------

const scored = rows.filter((row) => !row.error);
const withBaseline = scored.filter((row) => row.note !== "no-baseline");
const headline = withBaseline.filter((row) => !row.note.includes("baseline-is-page-brand"));
const matchCount = headline.filter((row) => row.match || row.noneCountsAsMatch).length;

const bySite = {};
for (const row of headline) {
  bySite[row.site] ??= { total: 0, match: 0 };
  bySite[row.site].total += 1;
  if (row.match || row.noneCountsAsMatch) bySite[row.site].match += 1;
}

mkdirSync(OUT_DIR, { recursive: true });
writeFileSync(join(OUT_DIR, "jev-answers.json"), JSON.stringify({ rows, rawResponses }, null, 2));

console.log("\n===== summary =====");
for (const [site, stat] of Object.entries(bySite)) {
  console.log(`${site}: ${stat.match}/${stat.total}`);
}
console.log(`total: ${matchCount}/${headline.length}`);
const usageTotals = rawResponses.reduce(
  (acc, item) => ({
    input: acc.input + (item.usage?.input_tokens ?? 0),
    output: acc.output + (item.usage?.output_tokens ?? 0),
  }),
  { input: 0, output: 0 },
);
console.log(`tokens: in=${usageTotals.input} out=${usageTotals.output} over ${rawResponses.length} requests`);

const disagreements = headline.filter((row) => !(row.match || row.noneCountsAsMatch));
if (disagreements.length) {
  console.log("\ndisagreements:");
  for (const row of disagreements) {
    console.log(`  [${row.site}/${row.kind}] baseline=${row.baseline.slice(0, 40)} | jev=${row.jevChoice.slice(0, 40)} (conf=${row.confidence})`);
  }
}
