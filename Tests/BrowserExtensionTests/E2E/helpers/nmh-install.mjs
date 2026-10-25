// Install/uninstall the E2E stub native messaging host manifest.
//
// The extension resolves HOST_NAME ("com.macidm.host") through the browser's
// native messaging manifest lookup. To keep the stub fully sandboxed from the
// user's real registration, the preferred strategy is a manifest inside the
// test run's --user-data-dir; `userDataDirNMHDir()` returns that candidate
// location and `probeUserDataDirSupport()` in the harness verifies empirically
// whether the browser actually consults it. When it does not, the suite fails
// fast with setup instructions instead of silently hitting the real host.

import { chmodSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { homedir } from "node:os";
import { join } from "node:path";
import { readFile } from "node:fs/promises";

// Same derivation as Tests/BrowserExtensionTests/Unit/manifest.test.mjs: the
// manifest ships a public "key", so an unpacked load gets this fixed ID.
export async function computeExtensionID() {
  const manifestURL = new URL("../../../../BrowserExtension/chrome/manifest.json", import.meta.url);
  const manifest = JSON.parse(await readFile(manifestURL, "utf8"));
  const digest = createHash("sha256").update(Buffer.from(manifest.key, "base64")).digest();
  return [...digest.subarray(0, 16)]
    .flatMap((byte) => [byte >> 4, byte & 0x0f])
    .map((nibble) => String.fromCharCode("a".charCodeAt(0) + nibble))
    .join("");
}

export function extensionRoot() {
  return new URL("../../../../BrowserExtension/chrome/", import.meta.url).pathname;
}

export function userDataDirNMHDir(userDataDir) {
  return join(userDataDir, "NativeMessagingHosts");
}

// Fixed per-browser lookup directories (profile-independent on macOS). Only
// used when the user-data-dir probe fails; each entry also reports whether a
// conflicting real "com.macidm.host" registration exists there.
export function fixedNMHDir(browser) {
  const library = join(homedir(), "Library", "Application Support");
  const table = {
    chrome: join(library, "Google", "Chrome", "NativeMessagingHosts"),
    edge: join(library, "Microsoft Edge", "NativeMessagingHosts"),
    brave: join(library, "BraveSoftware", "Brave-Browser", "NativeMessagingHosts"),
    chromium: join(library, "Chromium", "NativeMessagingHosts"),
  };
  return table[browser] ?? null;
}

export const STUB_HOST_NAME = "com.macidm.host";
export const PROBE_HOST_NAME = "com.macidm.e2e.probe";

const STUB_PATH = new URL("../../../Support/takeover-stub-native-host.mjs", import.meta.url).pathname;

let EXTENSION_ID = "";

/// Write the wrapper + manifest for `name` into manifestDir. Returns the
/// manifest path. The wrapper hardcodes the current Node executable so the
/// NMH spawn does not depend on PATH inside Chrome's context.
export async function installStubHostManifest({ name, manifestDir, controlDir }) {
  const extensionID = EXTENSION_ID || (EXTENSION_ID = await computeExtensionID());
  mkdirSync(manifestDir, { recursive: true });
  const wrapperPath = join(manifestDir, `${name}.macidm-e2e-wrapper.sh`);
  const stubCommand = [
    "#!/bin/sh",
    `exec '${process.execPath}' '${STUB_PATH}' '${controlDir}'`,
    "",
  ].join("\n");
  writeFileSync(wrapperPath, stubCommand, { mode: 0o755 });
  const manifestPath = join(manifestDir, `${name}.json`);
  const manifest = {
    name,
    description: "MacIDM E2E stub native messaging host (test-only)",
    path: wrapperPath,
    type: "stdio",
    allowed_origins: [`chrome-extension://${extensionID}/`],
  };
  writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o644 });
  return { manifestPath, wrapperPath };
}

export function uninstallStubHostManifest({ name, manifestDir }) {
  rmSync(join(manifestDir, `${name}.json`), { force: true });
  rmSync(join(manifestDir, `${name}.macidm-e2e-wrapper.sh`), { force: true });
}
