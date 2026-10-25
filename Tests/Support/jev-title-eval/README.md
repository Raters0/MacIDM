# jev-title-eval — Jev 标题获取评测工具

评估 TypeSafe Jev（System One 判断模型）在 MacIDM 视频标题截获场景上能否替代/仲裁
现有的按站点手写规则。结论与数据见 `docs/reports/jev-title-eval-2026-10-02.md`。

## 组成

- `capture-pages.mjs`：真实浏览器抓取 B 站 / 抖音 / YouTube 的首页卡片与详情页，
  在真实 DOM 上注入生产 `media-utils.js` 跑出基线标题（`resolvePageTitle`、
  `collectBilibiliPreviewIdentities` 等导出函数），并用零站点知识的通用收割器
  收集候选字符串。输出 `pages.json`。
- `run-jev-eval.mjs`：把候选组装成 Jev choice 问题（含 `none` 选项）逐页调用，
  与基线对比并输出 `jev-answers.json` 与控制台汇总。

## 运行

```sh
# playwright-core 不进仓库依赖，装到临时目录
npm i --prefix "${TMPDIR:-/tmp}/macidm-jev-eval" playwright-core

node Tests/Support/jev-title-eval/capture-pages.mjs "${TMPDIR:-/tmp}/macidm-jev-eval/pages"
TYPESAFE_API_KEY=<key> node Tests/Support/jev-title-eval/run-jev-eval.mjs \
  "${TMPDIR:-/tmp}/macidm-jev-eval/pages" "${TMPDIR:-/tmp}/macidm-jev-eval/pages"
```

## 边界

- 抓取的页面数据、候选、答案全部落在调用方指定的输出目录（默认 TMPDIR），
  不进入版本库（Tests/AGENTS.md：下载 fixtures 与本地状态在源码之外）。
- API 密钥只从 `TYPESAFE_API_KEY` 环境变量读取；两个脚本都不含、不落盘密钥。
- 证据等级：真实站点 HTML + 生产规则函数，**不是**扩展端到端证据；本机网络
  环境限制（YouTube watch 页 reCAPTCHA、未登录空首页）造成的替代面在
  `pages.json` 的 `note` 字段与评测报告中逐条标注。
