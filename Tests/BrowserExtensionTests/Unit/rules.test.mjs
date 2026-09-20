import assert from "node:assert/strict";
import test from "node:test";

import { DEFAULT_SETTINGS } from "../../../BrowserExtension/chrome/src/shared/constants.js";
import { shouldTakeover, isBodyCarryingMethod } from "../../../BrowserExtension/chrome/src/background/rules.js";

test("only body-carrying methods are treated as non-replayable (HEAD probe must not block takeover)", () => {
  assert.equal(isBodyCarryingMethod("POST"), true);
  assert.equal(isBodyCarryingMethod("put"), true);
  assert.equal(isBodyCarryingMethod("PATCH"), true);
  assert.equal(isBodyCarryingMethod("DELETE"), true);
  // A player's HEAD probe of the same media URL must NOT suppress the later
  // GET download takeover.
  assert.equal(isBodyCarryingMethod("HEAD"), false);
  assert.equal(isBodyCarryingMethod("OPTIONS"), false);
  assert.equal(isBodyCarryingMethod("GET"), false);
  assert.equal(isBodyCarryingMethod(""), false);
  assert.equal(isBodyCarryingMethod(undefined), false);
});

test("known matching file above threshold is taken over", () => {
  const result = shouldTakeover(
    {
      id: 1,
      url: "https://example.com/archive.zip",
      filename: "/tmp/archive.zip",
      totalBytes: DEFAULT_SETTINGS.minimumBytes + 1,
    },
    DEFAULT_SETTINGS,
  );
  assert.equal(result.takeOver, true);
});

test("unknown size is preserved by Chrome when takeoverAllDownloads is off", () => {
  const settings = { ...DEFAULT_SETTINGS, takeoverAllDownloads: false };
  const result = shouldTakeover(
    {
      id: 2,
      url: "https://example.com/archive.zip",
      filename: "/tmp/archive.zip",
      totalBytes: -1,
    },
    settings,
  );
  assert.deepEqual(result, { takeOver: false, reason: "unknown-size" });
});

test("takeoverAllDownloads takes over unknown-size downloads", () => {
  const result = shouldTakeover(
    {
      id: 2,
      url: "https://example.com/archive.zip",
      filename: "/tmp/archive.zip",
      totalBytes: -1,
    },
    DEFAULT_SETTINGS,
  );
  assert.deepEqual(result, { takeOver: true, reason: "takeover-all" });
});

test("explicit context menu action overrides size and type rules", () => {
  const result = shouldTakeover(
    {
      id: 3,
      url: "https://example.com/data.bin",
      filename: "/tmp/data.bin",
      totalBytes: 10,
    },
    DEFAULT_SETTINGS,
    true,
  );
  assert.deepEqual(result, { takeOver: true, reason: "explicit" });
});

test("final URL metadata can identify a Docker installer before Chrome assigns a filename", () => {
  const result = shouldTakeover(
    {
      id: 4,
      url: "https://desktop.docker.com/linux/main/amd64/docker-desktop.dmg",
      finalUrl: "https://desktop.docker.com/linux/main/amd64/docker-desktop.dmg",
      filename: "/tmp/download",
      totalBytes: DEFAULT_SETTINGS.minimumBytes + 1,
    },
    DEFAULT_SETTINGS,
  );
  assert.equal(result.takeOver, true);
});
