// Unit tests for the Download All filter syntax and rename template
// (shared/download-all-tools.js). The module is pure on purpose: the page
// and these tests share the exact production code.
import assert from "node:assert/strict";
import { test } from "node:test";

import {
  applyRenameMask,
  compileFilterTerm,
  matchesFilterQuery,
  parseFilterTerms,
  renderRenames,
} from "../../../BrowserExtension/chrome/src/shared/download-all-tools.js";

test("filter: plain terms keep substring semantics", () => {
  const predicate = compileFilterTerm("Episode 12");
  assert.equal(predicate("my favorite episode 12.mp4 https://cdn.example.test/e12"), true);
  assert.equal(predicate("episode 13"), false);
});

test("filter: glob terms match unanchored with * and ?", () => {
  const predicate = compileFilterTerm("*.mp?");
  assert.equal(predicate("talk https://example.com/a/keynote.mp4"), true);
  assert.equal(predicate("talk https://example.com/a/keynote.m3u8"), false);
});

test("filter: /regex/ terms are case-insensitive", () => {
  const predicate = compileFilterTerm("/ep\\d{2}/");
  assert.equal(predicate("Lecture EP07 notes"), true);
  assert.equal(predicate("Lecture EP7 notes"), false);
});

test("filter: an invalid regex term degrades to substring instead of blanking the list", () => {
  const predicate = compileFilterTerm("/ep(/");
  // Treated as a literal substring: no match means no match, not a crash.
  assert.equal(typeof predicate, "function");
  assert.equal(predicate("contains ep( here"), true);
});

test("filter: commas OR terms, and commas inside a regex stay inside the term", () => {
  assert.equal(matchesFilterQuery("alpha https://x.test/a.png", "beta, *.png"), true);
  assert.equal(matchesFilterQuery("gamma https://x.test/a.jpg", "beta, *.png"), false);
  // /a{1,3}/ must survive the comma split as one regex term.
  assert.equal(matchesFilterQuery("aaa file", "/a{1,3}/, zzz"), true);
});

test("filter: empty query matches everything", () => {
  assert.deepEqual(parseFilterTerms(""), []);
  assert.deepEqual(parseFilterTerms("   "), []);
  assert.equal(matchesFilterQuery("anything", ""), true);
});

test("rename: tokens render page title, url stem, number and date", () => {
  const name = applyRenameMask("*pagetitle* *num*.*ext*", {
    url: "https://cdn.example.test/lectures/session-07.mp4",
    pageTitle: "机器学习 课程",
    index: 3,
  });
  assert.equal(name, "机器学习 课程 3.mp4");
});

test("rename: a template without an extension keeps the original one", () => {
  const name = applyRenameMask("*pagetitle* 第 *num* 集", {
    url: "https://cdn.example.test/lectures/session-07.mp4",
    pageTitle: "深度学习",
    index: 1,
  });
  assert.equal(name, "深度学习 第 1 集.mp4");
});

test("rename: path separators in the page title are neutralized", () => {
  const name = applyRenameMask("*pagetitle*", {
    url: "https://cdn.example.test/a/file.bin",
    pageTitle: "../../etc/passwd",
    index: 1,
  });
  assert.equal(name.includes("/"), false);
  assert.equal(name.includes("\\"), false);
});

test("rename: an empty template returns null so normal naming applies", () => {
  assert.equal(applyRenameMask("   ", { url: "https://x.test/a.mp4", pageTitle: "t", index: 1 }), null);
});

test("rename: ordinary letters survive sanitizing (regression: 'r' was stripped)", () => {
  const name = applyRenameMask("*pagetitle*", {
    url: "https://cdn.example.test/a/trailer.mp4",
    pageTitle: "Star Wars Trailer",
    index: 1,
  });
  assert.equal(name, "Star Wars Trailer.mp4");
  assert.equal(
    applyRenameMask("*name*", { url: "https://cdn.example.test/recording.mp3", pageTitle: "", index: 1 }),
    "recording.mp3",
  );
});

test("rename: *num* is zero-padded to the selection size", () => {
  const options = { url: "https://cdn.example.test/a.mp4", pageTitle: "Ep", index: 3 };
  assert.equal(applyRenameMask("*num*", { ...options, total: 12 }), "03.mp4");
  assert.equal(applyRenameMask("*num*", { ...options, total: 120 }), "003.mp4");
  assert.equal(applyRenameMask("*num*", { ...options, total: 5 }), "3.mp4");
});

test("rename: renderRenames numbers in selection order and counts duplicates", () => {
  const links = [
    { url: "https://cdn.example.test/x.mp4", text: "Talk" },
    { url: "https://cdn.example.test/y.mp4", text: "Talk" },
  ];
  const numbered = renderRenames("*pagetitle* *num*", links);
  assert.deepEqual(numbered.names, {
    "https://cdn.example.test/x.mp4": "Talk 1.mp4",
    "https://cdn.example.test/y.mp4": "Talk 2.mp4",
  });
  assert.equal(numbered.duplicates, 0);
  assert.equal(renderRenames("*pagetitle*", links).duplicates, 2);
  assert.deepEqual(renderRenames("  ", links), { names: {}, duplicates: 0 });
});
