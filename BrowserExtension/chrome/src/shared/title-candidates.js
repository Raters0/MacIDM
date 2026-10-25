// 通用标题候选收割器（technical-spec §8.1 语义判断服务；chrome-extension-spec
// §7.1.1）。零站点知识：不含任何站点名或站点专属选择器，只按结构收割候选
// 标题字符串，供 App 的语义判断服务仲裁 filenameHint。
//
// 边界：仅在用户显式提交（media.download）时由 overlay 调用；产出 ≤10 条、
// 每条去空白后 2–200 字符、全串去重；卡片级候选排在页级候选之前。
(function installMacIDMTitleCandidates(global) {
  const MAX_CANDIDATES = 10;
  const MIN_TEXT = 2;
  const MAX_TEXT = 200;
  // 媒体元素向上找卡片祖先的最大层数；卡片祖先是「第一个含非空文本链接的祖先」。
  const MAX_ANCESTOR_HOPS = 5;

  function textOf(value) {
    return String(value ?? "").replace(/\s+/gu, " ").trim();
  }

  /// 纯函数：修剪、长度过滤（2–200 字符）、全串去重（大小写不敏感）、截断到
  /// 上限并保持原顺序。DOM 收集层只产出 [text, source]，过滤规则集中在这里
  /// 以便 Node 侧测试锁定边界。
  function normalizeCandidates(entries, limit = MAX_CANDIDATES) {
    const seen = new Set();
    const out = [];
    for (const entry of entries) {
      if (!entry) continue;
      const text = textOf(entry.text);
      if (text.length < MIN_TEXT || text.length > MAX_TEXT) continue;
      const key = text.toLowerCase();
      if (seen.has(key)) continue;
      seen.add(key);
      out.push({
        text,
        source: String(entry.source ?? "unknown"),
        scope: entry.scope === "card" ? "card" : "page",
      });
      if (out.length >= limit) break;
    }
    return out;
  }

  function collectFromScope(scope, push) {
    for (const el of scope.querySelectorAll("h1,h2,h3,h4,h5,h6")) {
      push(el.textContent, "heading");
    }
    for (const el of scope.querySelectorAll('[class*="title" i],[class*="tit" i]')) {
      push(el.textContent, "title-class");
    }
    for (const img of scope.querySelectorAll("img[alt]")) {
      push(img.getAttribute("alt"), "img-alt");
    }
    for (const el of scope.querySelectorAll("[aria-label]")) {
      push(el.getAttribute("aria-label"), "aria-label");
    }
    for (const a of scope.querySelectorAll("a[href]")) {
      const text = textOf(a.textContent);
      if (text.length >= 6 && text.length <= 80) push(text, "link-text");
    }
    // title 命名属性（如 data-feed-*-title）：名字含 title 的属性值本身。
    let scanned = 0;
    for (const el of scope.querySelectorAll("*")) {
      if (scanned >= 400) break;
      scanned += 1;
      for (const attr of el.attributes) {
        if (!attr.name.toLowerCase().includes("title")) continue;
        const value = String(attr.value ?? "");
        if (value.length < MIN_TEXT || value.length > MAX_TEXT) continue;
        if (/^(javascript:|https?:\/\/)/i.test(value)) continue;
        if (/^[a-z0-9_$ .:-]*$/i.test(value) && value.length < 12) continue;
        push(value, `${attr.name}@attr`);
      }
    }
  }

  /// 卡片祖先：从媒体元素向上 ≤5 层，取首个含非空文本链接（≥6 字符）的
  /// 祖先。找不到则返回 null（此时只有页级候选）。
  function findCardScope(element) {
    let node = element ?? null;
    for (let hop = 0; node && node.nodeType === 1 && hop < MAX_ANCESTOR_HOPS; hop += 1) {
      const hasTextLink = [...node.querySelectorAll("a[href]")].some((a) => {
        const text = textOf(a.textContent);
        return text.length >= 6;
      });
      if (hasTextLink) return node;
      node = node.parentElement;
    }
    return null;
  }

  function harvestCard(cardEl) {
    const entries = [];
    collectFromScope(cardEl, (text, source) => entries.push({ text, source, scope: "card" }));
    return normalizeCandidates(entries, MAX_CANDIDATES);
  }

  function harvestPage(doc) {
    const entries = [];
    const push = (text, source) => entries.push({ text, source, scope: "page" });
    push(doc.querySelector('meta[property="og:title"]')?.content, "og:title");
    push(doc.querySelector('meta[name="title"]')?.content, "meta-title");
    push(doc.title, "document.title");
    for (const el of doc.querySelectorAll("h1,h2,h3")) push(el.textContent, "heading");
    const body = doc.body || doc.documentElement;
    if (body) {
      let scanned = 0;
      for (const el of body.querySelectorAll("*")) {
        if (scanned >= 400) break;
        scanned += 1;
        for (const attr of el.attributes) {
          if (!attr.name.toLowerCase().includes("title")) continue;
          const value = String(attr.value ?? "");
          if (value.length < MIN_TEXT || value.length > MAX_TEXT) continue;
          if (/^(javascript:|https?:\/\/)/i.test(value)) continue;
          if (/^[a-z0-9_$ .:-]*$/i.test(value) && value.length < 12) continue;
          push(value, `${attr.name}@attr`);
        }
      }
      for (const img of [...body.querySelectorAll("img[alt]")].slice(0, 40)) {
        push(img.getAttribute("alt"), "img-alt");
      }
    }
    return normalizeCandidates(entries, MAX_CANDIDATES);
  }

  /// 入口：媒体元素锚定的卡片候选在前、页级候选在后，合并去重后截断到上限。
  /// `element` 缺失（面板找不到归属元素）时只有页级候选。
  function harvest({ doc, element } = {}) {
    if (!doc || typeof doc.querySelectorAll !== "function") return [];
    const cardScope = findCardScope(element);
    const merged = [];
    if (cardScope) {
      for (const entry of harvestCard(cardScope)) {
        merged.push({ text: entry.text, source: entry.source, scope: "card" });
      }
    }
    for (const entry of harvestPage(doc)) {
      merged.push({ text: entry.text, source: entry.source, scope: "page" });
    }
    return normalizeCandidates(merged, MAX_CANDIDATES);
  }

  global.MacIDMTitleCandidates = Object.freeze({
    harvest,
    normalizeCandidates,
  });
})(globalThis);
