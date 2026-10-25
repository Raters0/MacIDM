// 页内通用候选收割器（零站点知识）——被 capture-pages.mjs 与 ego-capture.mjs
// 以源码字符串形式注入页面执行。这是被测对象本身，不是工具函数库：
// 标题类结构 + 图片 alt + 链接文字 + title 命名属性 + 页面级 og/doc 标题，
// 每卡 ≤12 条（详情页 ≤14 条）。
(function installHarvester() {
  function textOf(value) {
    return String(value ?? "").replace(/\s+/gu, " ").trim();
  }
  function titleAttrScan(root, cap, push) {
    let n = 0;
    for (const el of root.querySelectorAll("*")) {
      if (n >= cap) return;
      if (!el.attributes) continue;
      for (const attr of el.attributes) {
        const name = attr.name.toLowerCase();
        if (!name.includes("title")) continue;
        const value = String(attr.value ?? "");
        if (value.length < 2 || value.length > 200) continue;
        if (/^(javascript:|https?:\/\/)/i.test(value)) continue;
        if (/^[a-z0-9_$ .:-]*$/i.test(value) && value.length < 12) continue;
        push(value, attr.name + "@attr");
        n += 1;
      }
    }
  }
  // 卡片级：标题类结构 + 图片 alt + 链接文字 + title 命名属性。绝不注入站点名。
  function harvestCard(cardEl) {
    const seen = new Set();
    const out = [];
    const push = (raw, source) => {
      const text = textOf(raw);
      if (text.length < 2 || text.length > 200) return;
      const key = text.toLowerCase();
      if (seen.has(key)) return;
      seen.add(key);
      out.push({ text, source });
    };
    for (const el of cardEl.querySelectorAll("h1,h2,h3,h4,h5,h6")) push(el.textContent, "heading");
    for (const el of cardEl.querySelectorAll('[class*="title" i],[class*="tit" i]')) {
      push(el.textContent, "title-class");
    }
    for (const img of cardEl.querySelectorAll("img[alt]")) push(img.getAttribute("alt"), "img-alt");
    for (const el of cardEl.querySelectorAll("[aria-label]")) push(el.getAttribute("aria-label"), "aria-label");
    for (const a of cardEl.querySelectorAll("a[href]")) {
      const text = textOf(a.textContent);
      if (text.length >= 6 && text.length <= 80) push(text, "link-text");
    }
    titleAttrScan(cardEl, 8, push);
    return out.slice(0, 12);
  }
  // 详情页级：og/doc 标题 + 文档主标题结构 + title 命名属性。
  function harvestPage(doc) {
    const seen = new Set();
    const out = [];
    const push = (raw, source) => {
      const text = textOf(raw);
      if (text.length < 2 || text.length > 200) return;
      const key = text.toLowerCase();
      if (seen.has(key)) return;
      seen.add(key);
      out.push({ text, source });
    };
    push(doc.querySelector('meta[property="og:title"]')?.content, "og:title");
    push(doc.querySelector('meta[name="title"]')?.content, "meta-title");
    push(doc.title, "document.title");
    for (const el of doc.querySelectorAll("h1,h2,h3")) push(el.textContent, "heading");
    const body = doc.body || doc.documentElement;
    if (body) titleAttrScan(body, 12, push);
    for (const img of [...doc.querySelectorAll("img[alt]")].slice(0, 40)) {
      push(img.getAttribute("alt"), "img-alt");
    }
    return out.slice(0, 14);
  }
  globalThis.MacIDMHarvest = { harvestCard, harvestPage };
})();
