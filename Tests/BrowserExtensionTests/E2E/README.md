# 接管 E2E 套件（chrome-extension-spec §10.2）

以真实 Chromium 浏览器加载开发版扩展，对「浏览器下载接管」全流程做可重复的自动化验证。

## 运行

```bash
node --test Tests/BrowserExtensionTests/E2E/*.test.mjs
```

环境变量：

- `MACIDM_E2E_BROWSER_PATH=<binary>` — 覆盖浏览器可执行文件；
- `MACIDM_E2E_HEADED=1` — 有头模式运行（默认 `--headless=new`）。

默认浏览器是 Chrome for Testing（自动解析 `~/.cache/puppeteer/chrome/` 下最新版本，
其次 `/Applications`）。不要用品牌版 Chrome ≥137（完全忽略 `--load-extension`）；
Edge 也会因全局 NMH 注册优先而被 setup 拒绝。

## 架构

- `helpers/cdp.mjs` — 零依赖 CDP 驱动：拉起浏览器、附加扩展 service worker（探测 API
  绑定就绪，避免僵尸会话）、控制台捕获、重启。
- `helpers/nmh-install.mjs` — 在测试 profile 的 `NativeMessagingHosts/` 安装/卸载桩 host
  manifest（扩展 ID 由 manifest key 推导，与 Unit/manifest.test.mjs 同一算法）。
- `helpers/takeover-harness.mjs` — 编排：NMH 影子校验、受控源、按用例重置（静默屏障 +
  消息文件清零）、消息/下载/主机生命周期观测、浏览器重启、扩展重新启用。
- `Tests/Support/takeover-origin-server.mjs` — 受控 `127.0.0.1` 源：锚点/重定向/签名
  query/Cookie/未知大小/慢速 trickled/POST 记录/blob 触发页与确定性载荷。
- `Tests/Support/takeover-stub-native-host.mjs` — 桩 native host：按 NMH 框架帧收发，
  把入站请求落盘为 JSONL，按 `behavior.json` 剧本回复（ready/pending/accepted/error/
  timeout/exit），用于模拟真 App 的成功与失败形态。

## 安全边界（重要）

- NMH manifest **必须在浏览器启动前**装入测试 profile（Chromium 启动时快照），否则
  `connectNative("com.macidm.host")` 会落到用户的全局真 host 注册、打真实 App——setup 的
  影子校验会把这种情况变成硬失败。
- 桩 host 只在测试 profile 的 NMH 命名空间内注册；套件结束后卸载，绝不改写用户全局目录。
- 断言证据来自：桩 host 的入站消息记录（App 侧视角）、`chrome.downloads.search`（浏览器侧
  视角）、`chrome.storage.local` 转储与扩展控制台捕获（脱敏视角）。这是桩 host 层证据，
  不代表 installed-App 或真实站点行为。

## 已知覆盖缺口

- Cookie 已授权附带领（需要用户手势授予 optional permission）——单元层覆盖 + 人工证据。
- cancel 失败降级（外部无法稳定构造）——`Unit/takeover-controller.test.mjs` 覆盖。
- 确认窗 120s 交互超时变体（自动化只覆盖 15s 请求超时）。
- Edge/Brave 兼容矩阵与带真 App 的全链路——人工/installed-App 证据层。
