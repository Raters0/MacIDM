import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";

const expectedExtensionID = "obaipbnfoifafgcpekkfkapjifjgbjag";

test("manifest public key produces the fixed development extension ID", async () => {
  const manifestURL = new URL("../../../BrowserExtension/chrome/manifest.json", import.meta.url);
  const manifest = JSON.parse(await readFile(manifestURL, "utf8"));
  const digest = createHash("sha256").update(Buffer.from(manifest.key, "base64")).digest();
  const extensionID = [...digest.subarray(0, 16)]
    .flatMap((byte) => [byte >> 4, byte & 0x0f])
    .map((nibble) => String.fromCharCode("a".charCodeAt(0) + nibble))
    .join("");

  assert.equal(extensionID, expectedExtensionID);
  assert.deepEqual(manifest.optional_permissions, ["cookies"]);
  assert.deepEqual(manifest.host_permissions, ["http://*/*", "https://*/*"]);
  assert.deepEqual(manifest.content_scripts[0].matches, ["http://*/*", "https://*/*"]);
  assert.deepEqual(manifest.content_scripts[0].js, [
    "src/shared/media-utils.js",
    "src/shared/youtube-format-utils.js",
    "src/shared/media-presentation.js",
    "src/shared/sniff-governance.js",
    "src/shared/category.js",
    "src/shared/i18n.js",
    "src/shared/locale-zh-cn.js",
    "src/shared/locale-en.js",
    "src/shared/panel-ui.js",
    "src/shared/slim-scrollbar.js",
    "src/content/discovery.js",
    "src/content/content-script.js",
    "src/content/overlay.js",
  ]);
  assert.deepEqual(manifest.content_scripts[1].matches, ["http://*/*", "https://*/*"]);
  assert.deepEqual(manifest.content_scripts[1].js, ["src/content/fetch-interceptor.js"]);
  assert.equal(manifest.content_scripts[1].world, "MAIN");
  assert.equal(manifest.content_scripts[1].run_at, "document_start");
  assert.equal("optional_host_permissions" in manifest, false);
  assert.equal(manifest.permissions.includes("webRequestBlocking"), false);
});
