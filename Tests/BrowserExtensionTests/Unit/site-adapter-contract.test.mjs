// Site-adapter contract replay suite (chrome-extension-spec §5.5.1).
//
// Every site adapter must produce candidates that conform to the uniform
// output contract — url/mime/size/filenameHint/filenameHintSource — and title
// hints that survive the zero-site-knowledge title-candidates normalizer.
// Fixtures in Tests/Fixtures/site-adapters/ capture real payload shapes; when
// a site changes format, update the fixture first, then the adapter, and the
// replay below locks the contract in both directions.
//
// Adding a site adapter = one fixture file + one entry in ADAPTERS.

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const SHARED_ROOT = "../../../BrowserExtension/chrome/src/shared";
const SOURCES = [
  "title-candidates.js",
  "tiktok-detail-cache.js",
  "douyin-detail-cache.js",
];

const FIXTURES = [
  {
    fixture: "tiktok-detail-item.json",
    globalName: "MacIDMTikTokDetailCache",
  },
  {
    fixture: "douyin-modal-entry.json",
    globalName: "MacIDMDouyinDetailCache",
  },
];

const ALLOWED_HINT_SOURCES = new Set([
  "titleDerived",
  "browserResolved",
  "serverSuggested",
  "urlPath",
  "fallback",
]);

async function makeContext() {
  const context = vm.createContext({
    URL,
    Date,
    Math,
    JSON,
    TextEncoder,
    document: null,
  });
  context.globalThis = context;
  for (const name of SOURCES) {
    const source = await readFile(new URL(`${SHARED_ROOT}/${name}`, import.meta.url), "utf8");
    vm.runInContext(source, context, { filename: name });
  }
  return context;
}

async function loadFixture(name) {
  return JSON.parse(
    await readFile(new URL(`../../Fixtures/site-adapters/${name}`, import.meta.url), "utf8"),
  );
}

/// Store the fixture through the adapter's declared ingest step and collect
/// the candidates it contributes for the fixture's page URL.
function replay(context, adapter, fixture) {
  adapter.clear();
  const ingest = fixture.ingest && adapter[fixture.ingest];
  adapter.store(ingest ? ingest(fixture.entry) : fixture.entry);
  return adapter.associatedCandidates(fixture.pageURL);
}

test("every registered site adapter replays its fixture within the contract", async () => {
  const context = await makeContext();
  for (const registration of FIXTURES) {
    const fixture = await loadFixture(registration.fixture);
    const adapter = context[registration.globalName];
    assert.ok(adapter, `${registration.globalName} must install itself on globalThis`);

    const candidates = replay(context, adapter, fixture);
    assert.equal(
      candidates.length,
      fixture.expectedCandidateCount,
      `${fixture.name}: candidate count drifted`,
    );

    const top = candidates[0];
    assert.equal(top.url, fixture.expectedTop.url, `${fixture.name}: top URL changed`);
    assert.equal(top.filenameHint, fixture.expectedTop.filenameHint, `${fixture.name}: title hint changed`);
    assert.equal(
      top.filenameHintSource,
      fixture.expectedTop.filenameHintSource,
      `${fixture.name}: hint trust source changed`,
    );

    // The uniform output contract (§5.5.1): every candidate carries the full
    // field set with safe values, regardless of site.
    for (const candidate of candidates) {
      assert.match(candidate.url, /^https?:\/\//u, `${fixture.name}: candidate URL must be http(s)`);
      assert.equal(typeof candidate.mime, "string", `${fixture.name}: mime required`);
      assert.equal(typeof candidate.size, "number", `${fixture.name}: size required`);
      assert.ok(Number.isFinite(candidate.size) && candidate.size >= 0, `${fixture.name}: size must be finite`);
      assert.equal(typeof candidate.filenameHint, "string", `${fixture.name}: filenameHint required`);
      assert.ok(
        ALLOWED_HINT_SOURCES.has(candidate.filenameHintSource),
        `${fixture.name}: unknown filenameHintSource ${candidate.filenameHintSource}`,
      );
    }
  }
});

test("adapter title hints survive the zero-site-knowledge normalizer unchanged", async () => {
  const context = await makeContext();
  const normalizer = context.MacIDMTitleCandidates;
  assert.ok(normalizer, "MacIDMTitleCandidates must install itself on globalThis");

  for (const registration of FIXTURES) {
    const fixture = await loadFixture(registration.fixture);
    const adapter = context[registration.globalName];
    const candidates = replay(context, adapter, fixture);
    const normalized = normalizer.normalizeCandidates(
      candidates.map((candidate) => ({ text: candidate.filenameHint, source: "adapter" })),
    );
    assert.ok(normalized.length >= 1, `${fixture.name}: hint must survive normalization`);
    assert.equal(
      normalized[0].text,
      candidates[0].filenameHint,
      `${fixture.name}: adapter hint must already be in normalized form (2–200 chars, trimmed)`,
    );
  }
});
