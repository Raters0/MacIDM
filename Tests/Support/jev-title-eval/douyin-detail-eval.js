// 抖音 modal/详情页统一评估表达式——被 capture-pages.mjs 与 ego-capture.mjs
// 以源码字符串形式 page.evaluate 注入。锚点取最大可见 video（modal 态
// document.querySelector("video") 可能落在背景 feed 卡片上）；expectedTitle 用
// 生产 douyinContentTitle 的语义字段（video-desc）作对照，不进 Jev 候选。
(() => {
  const visible = [...document.querySelectorAll("video")].filter((v) => {
    const rect = v.getBoundingClientRect();
    return rect.width > 100 && rect.height > 100;
  });
  visible.sort((a, b) => {
    const rectA = a.getBoundingClientRect();
    const rectB = b.getBoundingClientRect();
    return rectB.width * rectB.height - rectA.width * rectA.height;
  });
  const video = visible[0] ?? document.querySelector("video") ?? null;
  const anchor = video?.closest(".xgplayer, [class*='playerContainer']")?.querySelector("video") ?? video;
  let expected = "";
  let scope = anchor?.closest("[class*='playerContainer'], .xgplayer");
  for (let hop = 0; scope && hop < 5; hop += 1) {
    const desc = scope.querySelector('[data-e2e="video-desc"]')?.textContent;
    if (desc) { expected = desc; break; }
    scope = scope.parentElement;
  }
  return {
    documentTitle: document.title || "",
    ogTitle: document.querySelector('meta[property="og:title"]')?.content ?? "",
    h1: String(document.querySelector("h1")?.textContent ?? "").replace(/\s+/gu, " ").trim(),
    baselineTitle: globalThis.MacIDMMediaUtils.resolvePageTitle(document, anchor) || "",
    expectedTitle: String(expected ?? "").replace(/\s+/gu, " ").trim().slice(0, 200),
    candidates: globalThis.MacIDMHarvest.harvestPage(document),
  };
})()
