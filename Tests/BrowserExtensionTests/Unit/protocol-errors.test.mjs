import assert from "node:assert/strict";
import test from "node:test";

// Importing protocol.js loads i18n-access.js, which installs the i18n core
// plus both locale catalogs (default language: zh-CN).
import { safeErrorMessage } from "../../../BrowserExtension/chrome/src/shared/protocol.js";
import { i18n } from "../../../BrowserExtension/chrome/src/shared/i18n-access.js";

const STRUCTURED_MEDIA_CODES = [
  "MEDIA_AUTH_REQUIRED",
  "MEDIA_COOKIE_UNAVAILABLE",
  "MEDIA_TOOL_UNAVAILABLE",
  "MEDIA_TOOL_UPDATE_SUGGESTED",
  "MEDIA_NETWORK_FAILURE",
  "MEDIA_NO_FORMATS",
  "MEDIA_CLEANUP_FAILED",
  "MEDIA_UNSUPPORTED",
  "MEDIA_INVALID",
];

test("structured media error codes map to distinct localized messages", async () => {
  await i18n.setLanguage("zh-CN");
  const messages = new Set(
    STRUCTURED_MEDIA_CODES.map((code) => safeErrorMessage(code, undefined)),
  );
  // Every category must have its own copy — none may collapse into a
  // shared generic string (chrome-extension-spec §5.8).
  assert.equal(messages.size, STRUCTURED_MEDIA_CODES.length);
  assert.equal(
    safeErrorMessage("MEDIA_AUTH_REQUIRED", undefined),
    "YouTube 要求登录或人机验证，无法解析画质。请先在浏览器登录该站点，或在解析失败行授权 Cookie 后重试。",
  );
  assert.equal(
    safeErrorMessage("MEDIA_TOOL_UNAVAILABLE", undefined),
    "未找到可用的 yt-dlp，请安装或更新后再试。",
  );
});

test("structured error messages localize to English", async () => {
  await i18n.setLanguage("en");
  assert.equal(
    safeErrorMessage("MEDIA_AUTH_REQUIRED", undefined),
    "YouTube requires sign-in or a bot check, so qualities could not be parsed. Sign in to the site in the browser first, or authorize cookies on the failed row and retry.",
  );
  assert.equal(
    safeErrorMessage("MEDIA_NETWORK_FAILURE", undefined),
    "The network or proxy connection failed or timed out; check the network and try again.",
  );
  await i18n.setLanguage("zh-CN");
});

test("the supplied message is never surfaced, even when it contains secrets", async () => {
  await i18n.setLanguage("zh-CN");
  // Raw yt-dlp stderr can carry URLs, signed query parameters, or cookie
  // fragments. The localized catalog copy must win over any supplied text.
  const supplied =
    "ERROR: unable to download https://rr.example.com/videoplayback?token=SECRET_SIGNATURE&session=abc";
  const message = safeErrorMessage("MEDIA_NETWORK_FAILURE", supplied);

  assert.equal(
    message,
    "网络或代理连接失败或超时，请检查网络后重试。",
  );
  assert.equal(message.includes("SECRET_SIGNATURE"), false);
  assert.equal(message.includes("videoplayback"), false);
});

test("unknown codes fall back to the generic message with the code embedded", () => {
  const message = safeErrorMessage("SOME_FUTURE_CODE", "anything");
  assert.ok(message.includes("SOME_FUTURE_CODE"));
});
