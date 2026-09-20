import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const source = await readFile(
  new URL("../../../BrowserExtension/chrome/src/shared/media-utils.js", import.meta.url),
  "utf8",
);
const context = vm.createContext({ URL });
context.globalThis = context;
vm.runInContext(source, context);
const mediaUtils = context.MacIDMMediaUtils;

/// Minimal element tree sufficient for the card-identity selectors used by
/// extractBilibiliCardIdentity / collectBilibiliPreviewIdentities.
function createNode({ tag = "div", className = "", text = "", attrs = {}, children = [] } = {}) {
  const node = {
    nodeType: 1,
    tagName: tag.toUpperCase(),
    className,
    textContent: text,
    parentElement: null,
    attrs,
    children,
    getAttribute(name) {
      return this.attrs[name] ?? null;
    },
  };
  for (const child of children) child.parentElement = node;

  function walk(n, fn) {
    fn(n);
    for (const c of n.children ?? []) walk(c, fn);
  }

  function parseSimple(part) {
    const out = {};
    if (part.startsWith(".")) out.classes = part.slice(1).split(".");
    const tagMatch = part.match(/^([a-zA-Z][a-zA-Z0-9]*)/u);
    if (tagMatch) out.tag = tagMatch[1];
    const classMatch = part.match(/\[class\*=['"]([^'"]+)['"]\]/u);
    if (classMatch) out.classIncludes = classMatch[1];
    const hrefMatch = part.match(/\[href\*=['"]([^'"]+)['"]\]/u);
    if (hrefMatch) out.hrefIncludes = hrefMatch[1];
    return out;
  }

  function matches(n, simple) {
    if (simple.classes?.some(name => !String(n.className).split(/\s+/u).includes(name))) return false;
    if (simple.tag && n.tagName.toLowerCase() !== simple.tag.toLowerCase()) return false;
    if (simple.classIncludes && !String(n.className).includes(simple.classIncludes)) return false;
    if (simple.hrefIncludes) {
      const href = n.getAttribute("href") || "";
      if (!href.includes(simple.hrefIncludes)) return false;
    }
    return true;
  }

  node.querySelector = (selector) => {
    for (const sel of String(selector).split(",").map((s) => s.trim()).filter(Boolean)) {
      const parts = sel.split(/\s+/u).filter(Boolean).map(parseSimple);
      if (parts.length === 0) continue;
      let found = null;
      walk(node, (n) => {
        if (found || n === node) return;
        if (!matches(n, parts[parts.length - 1])) return;
        if (parts.length === 1) {
          found = n;
          return;
        }
        let idx = parts.length - 2;
        let cur = n.parentElement;
        while (idx >= 0 && cur) {
          if (matches(cur, parts[idx])) {
            idx -= 1;
          }
          cur = cur.parentElement;
        }
        if (idx < 0) found = n;
      });
      if (found) return found;
    }
    return null;
  };

  node.querySelectorAll = (selector) => {
    const results = [];
    for (const sel of String(selector).split(",").map((s) => s.trim()).filter(Boolean)) {
      const simple = parseSimple(sel);
      walk(node, (n) => {
        if (n !== node && matches(n, simple)) results.push(n);
      });
    }
    return results;
  };

  node.closest = (selector) => {
    const parts = String(selector).split(",").map((s) => s.trim()).filter(Boolean);
    let cur = node;
    while (cur) {
      for (const part of parts) {
        if (matches(cur, parseSimple(part))) return cur;
      }
      cur = cur.parentElement;
    }
    return null;
  };

  return node;
}

function makeBilibiliPreviewCard({ bvid, title, withVideo = true } = {}) {
  const video = createNode({ tag: "video", className: "" });
  const player = createNode({
    tag: "div",
    className: "bpx-player-container",
    children: [video],
  });
  const hover = createNode({
    tag: "div",
    className: "bili-video-card__image--hover",
    children: withVideo ? [player] : [],
  });
  const coverLink = createNode({
    tag: "a",
    className: "bili-video-card__image--link",
    text: "添加至稍后再看61.8万2492",
    attrs: { href: `/video/${bvid}` },
  });
  const titleLink = createNode({
    tag: "a",
    text: title,
    attrs: { href: `/video/${bvid}` },
  });
  const heading = createNode({
    tag: "h3",
    className: "bili-video-card__info--tit",
    children: [titleLink],
  });
  const info = createNode({
    tag: "div",
    className: "bili-video-card__info",
    children: [heading],
  });
  const image = createNode({
    tag: "div",
    className: "bili-video-card__image",
    children: [coverLink, hover],
  });
  const card = createNode({
    tag: "div",
    className: "bili-video-card",
    children: [image, info],
  });
  const root = createNode({
    tag: "body",
    children: [card],
  });
  return { root, card, video, hover };
}

const HOME = "https://www.bilibili.com/";

test("bilibiliVideoIDFromURL accepts only /video/BV|av identities", () => {
  assert.equal(
    mediaUtils.bilibiliVideoIDFromURL("https://www.bilibili.com/video/BV1enYL6SEtU"),
    "BV1enYL6SEtU",
  );
  assert.equal(
    mediaUtils.bilibiliVideoIDFromURL("https://bilibili.com/video/av12345?p=2"),
    "av12345",
  );
  assert.equal(mediaUtils.bilibiliVideoIDFromURL(HOME), null);
  assert.equal(
    mediaUtils.bilibiliVideoIDFromURL("https://www.bilibili.com/bangumi/play/ep1"),
    null,
  );
  assert.equal(mediaUtils.bilibiliVideoIDFromURL("https://example.com/video/BV1"), null);
});

test("extractBilibiliCardIdentity reads bvid and heading from the enclosing card", () => {
  const { root, video } = makeBilibiliPreviewCard({
    bvid: "BV1enYL6SEtU",
    title: "高糖VS戒糖14天！真的差别很大吗？",
  });
  const identity = mediaUtils.extractBilibiliCardIdentity(video, HOME);
  assert.equal(identity?.bvid, "BV1enYL6SEtU");
  assert.equal(identity?.title, "高糖VS戒糖14天！真的差别很大吗？");
  assert.equal(identity?.pageURL, "https://www.bilibili.com/video/BV1enYL6SEtU");
  assert.ok(root);
});

test("extractBilibiliCardIdentity ignores cover-link overlay chrome as the title", () => {
  // Cover text is "添加至稍后再看…"; the heading must win.
  const { video } = makeBilibiliPreviewCard({ bvid: "BV1abc", title: "真实标题" });
  assert.equal(mediaUtils.extractBilibiliCardIdentity(video, HOME)?.title, "真实标题");
});

test("collectBilibiliPreviewIdentities is empty without a mounted card player", () => {
  const withoutPlayer = makeBilibiliPreviewCard({
    bvid: "BV1x",
    title: "标题",
    withVideo: false,
  });
  const identities = mediaUtils.collectBilibiliPreviewIdentities(withoutPlayer.root, HOME);
  assert.equal(identities.length, 0);
});

test("collectBilibiliPreviewIdentities skips watch pages and non-Bilibili hosts", () => {
  const { root, video } = makeBilibiliPreviewCard({ bvid: "BV1x", title: "标题" });
  assert.ok(video);
  assert.equal(
    mediaUtils.collectBilibiliPreviewIdentities(
      root,
      "https://www.bilibili.com/video/BV1watch",
    ).length,
    0,
  );
  assert.equal(
    mediaUtils.collectBilibiliPreviewIdentities(root, "https://example.com/").length,
    0,
  );
});

test("collectBilibiliPreviewIdentities returns one identity per mounted preview", () => {
  const a = makeBilibiliPreviewCard({ bvid: "BV1aaa", title: "视频甲" });
  const b = makeBilibiliPreviewCard({ bvid: "BV1bbb", title: "视频乙" });
  const body = createNode({
    tag: "body",
    children: [...a.root.children, ...b.root.children],
  });
  const identities = mediaUtils.collectBilibiliPreviewIdentities(body, HOME);
  assert.equal(identities.length, 2);
  assert.equal(identities.map((id) => id.bvid).sort().join(","), "BV1aaa,BV1bbb");
  assert.equal(
    identities.find((id) => id.bvid === "BV1aaa")?.title,
    "视频甲",
  );
});

test("coalesce synthesizes a preview adapter with the card title on the homepage", () => {
  const pageURL = HOME;
  const m4s = mediaUtils.normalizeMediaCandidate(
    {
      url: "https://809aj93l.edge.mountaintoys.cn:4483/upgcxcode/08/37/41786933708/41786933708-1-30011.m4s?e=token",
      mime: "video/mp4",
      size: 12345,
    },
    pageURL,
  );
  const result = mediaUtils.coalesceMediaCandidates(
    [m4s],
    "哔哩哔哩 (゜-゜)つロ 干杯~-bilibili",
    pageURL,
    [{ bvid: "BV1enYL6SEtU", pageURL: "https://www.bilibili.com/video/BV1enYL6SEtU", title: "高糖VS戒糖14天！" }],
  );

  const adapters = result.filter((c) => c?.siteAdapter === "bilibili");
  assert.equal(adapters.length, 1);
  assert.equal(adapters[0].url, "https://www.bilibili.com/video/BV1enYL6SEtU");
  assert.equal(adapters[0].displayName, "高糖VS戒糖14天！");
  assert.equal(adapters[0].filenameHint, "高糖VS戒糖14天！.mp4");
  // Preview-covered m4s (even on a rotating mirror host) is suppressed.
  assert.ok(
    result.every((c) => !String(c.url).includes("41786933708-1-30011.m4s")),
    "镜像域上的预览 m4s 不应再作为主候选出现",
  );
});

test("coalesce without preview identities does not treat the homepage as one video", () => {
  const pageURL = HOME;
  const m4s = mediaUtils.normalizeMediaCandidate(
    {
      url: "https://809aj93l.edge.mountaintoys.cn:4483/upgcxcode/08/37/41786933708/41786933708-1-30011.m4s",
      size: 99,
    },
    pageURL,
  );
  const result = mediaUtils.coalesceMediaCandidates(
    [m4s],
    "哔哩哔哩 (゜-゜)つロ 干杯~-bilibili",
    pageURL,
  );
  assert.ok(result.every((c) => c?.siteAdapter !== "bilibili"));
  assert.ok(
    result.some((c) => String(c.url).includes(".m4s")),
    "无预览身份时仍保留可发现的流观察",
  );
});

test("coalesce deduplicates repeated preview identities by bvid", () => {
  const result = mediaUtils.coalesceMediaCandidates(
    [],
    "",
    HOME,
    [
      { bvid: "BV1same", pageURL: "https://www.bilibili.com/video/BV1same", title: "甲" },
      { bvid: "BV1same", pageURL: "https://www.bilibili.com/video/BV1same", title: "乙" },
    ],
  );
  const adapters = result.filter((c) => c?.siteAdapter === "bilibili");
  assert.equal(adapters.length, 1);
  assert.equal(adapters[0].displayName, "甲");
});

test("second-pass coalesce does not duplicate an adapter already in the candidate list", () => {
  // Service worker re-runs coalesce on the page-world output.
  const first = mediaUtils.coalesceMediaCandidates(
    [],
    "",
    HOME,
    [{ bvid: "BV1pass", pageURL: "https://www.bilibili.com/video/BV1pass", title: "一遍" }],
  );
  const second = mediaUtils.coalesceMediaCandidates(
    first,
    "",
    HOME,
    [{ bvid: "BV1pass", pageURL: "https://www.bilibili.com/video/BV1pass", title: "一遍" }],
  );
  const adapters = second.filter((c) => c?.siteAdapter === "bilibili");
  assert.equal(adapters.length, 1);
  assert.equal(adapters[0].url, "https://www.bilibili.com/video/BV1pass");
});

test("coalesce keeps a complete m4s pair as fallback beside a preview adapter", () => {
  const videoURL = "https://cdn.example/1550776785-1-100022.m4s";
  const audioURL = "https://cdn.example/1550776785-1-30216.m4s";
  const result = mediaUtils.coalesceMediaCandidates(
    [
      mediaUtils.normalizeMediaCandidate({ url: videoURL, size: 100 }, HOME),
      mediaUtils.normalizeMediaCandidate({ url: audioURL, size: 50 }, HOME),
    ],
    "首页标题",
    HOME,
    [{ bvid: "BV1pair", pageURL: "https://www.bilibili.com/video/BV1pair", title: "配对回退" }],
  );
  assert.ok(result.some((c) => c?.siteAdapter === "bilibili" && c.displayName === "配对回退"));
  assert.ok(result.some((c) => c?.pairKind === "m4s-pair"));
});

test("watch-page adapter synthesis is unchanged by an empty preview list", () => {
  const pageURL = "https://www.bilibili.com/video/BV1watch";
  const result = mediaUtils.coalesceMediaCandidates(
    [
      mediaUtils.normalizeMediaCandidate(
        { url: "https://upos-sz-mirror08c.bilivideo.com/123/web.mp4", size: 2 },
        pageURL,
      ),
    ],
    "观看页标题",
    pageURL,
    [],
  );
  assert.equal(result.length, 1);
  assert.equal(result[0].siteAdapter, "bilibili");
  assert.equal(result[0].url, pageURL);
  assert.equal(result[0].displayName, "观看页标题");
});

test("card identity cannot escape a titleless card into its sibling", () => {
  const a = makeBilibiliPreviewCard({bvid:"BVaaa",title:""});
  const b = makeBilibiliPreviewCard({bvid:"BVbbb",title:"其他视频"});
  createNode({tag:"body",children:[a.card,b.card]});
  const id = mediaUtils.extractBilibiliCardIdentity(a.video, HOME);
  assert.equal(id.bvid, "BVaaa"); assert.equal(id.title, "");
});
