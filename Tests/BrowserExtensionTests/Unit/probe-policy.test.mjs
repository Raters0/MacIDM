import assert from "node:assert/strict";
import test from "node:test";

import {
  ProbeEvidenceLedger,
  decideAutoProbe,
  isLoopbackAddress,
  isPrivateAddress,
  isProbeContextValid,
  isPublicAddress,
  parseIPv4,
  parseIPv6,
} from "../../../BrowserExtension/chrome/src/background/probe-policy.js";

// ----------------------------------------------------------- address spellings

test("every inet_aton spelling of loopback reads as private", () => {
  const loopbackForms = ["127.0.0.1", "127.1", "127.0.1", "0x7f.0.0.1", "0177.0.0.1", "2130706433"];
  for (const host of loopbackForms) {
    assert.equal(isPrivateAddress(host), true, `${host} must be treated as private`);
  }
});

test("parseIPv4 normalizes short and radix forms to dotted quad", () => {
  assert.equal(parseIPv4("127.1"), "127.0.0.1");
  assert.equal(parseIPv4("10.1"), "10.0.0.1");
  assert.equal(parseIPv4("2130706433"), "127.0.0.1");
  assert.equal(parseIPv4("0x7f000001"), "127.0.0.1");
  assert.equal(parseIPv4("0177.0.0.1"), "127.0.0.1");
  assert.equal(parseIPv4("93.184.216.34"), "93.184.216.34");
});

test("parseIPv4 rejects values that overflow their byte count", () => {
  assert.equal(parseIPv4("1.2.3.256"), null);
  assert.equal(parseIPv4("256.1"), null);
  assert.equal(parseIPv4("4294967296"), null);
  assert.equal(parseIPv4("example.com"), null);
  assert.equal(parseIPv4("1.2.3.4.5"), null);
  assert.equal(parseIPv4("1..2"), null);
});

test("private and reserved IPv4 ranges are all rejected", () => {
  const blocked = [
    "0.0.0.0",
    "0.24.204.234",
    "10.0.0.5",
    "100.64.0.1",
    "127.0.0.1",
    "169.254.169.254",
    "172.16.0.1",
    "172.31.255.255",
    "192.0.0.1",
    "192.0.2.1",
    "192.168.1.1",
    "198.51.100.1",
    "203.0.113.1",
    "224.0.0.1",
    "239.255.255.255",
    "255.255.255.255",
  ];
  for (const host of blocked) {
    assert.equal(isPrivateAddress(host), true, `${host} must be blocked`);
  }
});

test("public IPv4 and hostnames are not private", () => {
  // Each value sits just outside the blocked range it is paired with below.
  for (const host of ["93.184.216.34", "172.15.0.1", "172.32.0.1", "100.128.0.1"]) {
    assert.equal(isPrivateAddress(host), false, `${host} is public`);
  }
  assert.equal(isPrivateAddress("media.example.com"), false);
});

test("CGNAT boundary is inclusive at 100.127 and exclusive at 100.128", () => {
  assert.equal(isPrivateAddress("100.64.0.0"), true);
  assert.equal(isPrivateAddress("100.127.255.255"), true);
  assert.equal(isPrivateAddress("100.128.0.0"), false);
});

test("IPv6 loopback, unspecified, mapped and local ranges are rejected", () => {
  const blocked = [
    "::1",
    "::",
    "[::1]",
    "[0:0:0:0:0:0:0:1]",
    "::ffff:127.0.0.1",
    "::ffff:7f00:1",
    "fe80::1",
    "[fe80::42]",
    "fc00::1",
    "fd12:3456::7890",
    "ff02::1",
  ];
  for (const host of blocked) {
    assert.equal(isPrivateAddress(host), true, `${host} must be blocked`);
  }
});

test("public IPv6 literals are accepted", () => {
  assert.equal(isPrivateAddress("2606:2800:220:1:248:1893:25c8:1946"), false);
  assert.equal(isPrivateAddress("[2606:2800:220:1::1]"), false);
});

test("parseIPv6 expands compression and embedded IPv4 tails", () => {
  assert.deepEqual(parseIPv6("::1"), [0, 0, 0, 0, 0, 0, 0, 1]);
  assert.deepEqual(parseIPv6("::ffff:127.0.0.1"), [0, 0, 0, 0, 0, 0xffff, 0x7f00, 1]);
  assert.equal(parseIPv6("::::1"), null);
  assert.equal(parseIPv6("1:2:3"), null);
  assert.equal(parseIPv6("gg::1"), null);
});

test("reserved hostnames and empty hosts are rejected", () => {
  for (const host of ["localhost", "nas.local", "router.internal", "printer", ""]) {
    assert.equal(isPrivateAddress(host), host !== "printer");
  }
});

test("isPublicAddress requires a real public address", () => {
  assert.equal(isPublicAddress("93.184.216.34"), true);
  assert.equal(isPublicAddress("10.0.0.1"), false);
  assert.equal(isPublicAddress(""), false);
  assert.equal(isPublicAddress(undefined), false);
});

test("isLoopbackAddress recognizes only the loopback ranges", () => {
  // A local HTTP proxy answers as the peer for every request, in whichever
  // spelling the stack happens to print.
  for (const host of [
    "127.0.0.1",
    "127.1",
    "127.23.45.6",
    "0177.0.0.1",
    "2130706433",
    "::1",
    "[::1]",
    "::ffff:127.0.0.1",
    "localhost",
  ]) {
    assert.equal(isLoopbackAddress(host), true, `${host} is loopback`);
  }
  // Private-but-not-loopback stays out: an intranet peer and a LAN proxy are
  // indistinguishable there, so the policy keeps failing closed instead.
  for (const host of [
    "10.0.0.1",
    "192.168.1.10",
    "169.254.1.1",
    "0.0.0.0",
    "::",
    "93.184.216.34",
    "cdn.example.com",
    "",
    undefined,
  ]) {
    assert.equal(isLoopbackAddress(host), false, `${host} is not loopback`);
  }
});

// ------------------------------------------------------------- admission rule

const publicEvidence = {
  url: "https://cdn.example.com/video.mp4",
  tabId: 7,
  generation: 0,
  ip: "93.184.216.34",
};

test("a candidate the network never observed is never probed", () => {
  // This is the forged-MAIN-World case: the URL appeared only in page-supplied
  // data, so it may not turn into an extension-issued request.
  const decision = decideAutoProbe({
    candidate: { url: "https://admin.corp.internal/leak.mp4" },
    evidence: null,
    pageURL: "https://evil.example/player",
    probeable: true,
  });
  assert.equal(decision.allowed, false);
  assert.equal(decision.reason, "private_target");

  const publicTarget = decideAutoProbe({
    candidate: { url: "https://cdn.example.com/video.mp4" },
    evidence: null,
    pageURL: "https://evil.example/player",
    probeable: true,
  });
  assert.equal(publicTarget.allowed, false);
  assert.equal(publicTarget.reason, "unobserved");
});

test("an observed public target is probed anonymously without redirects", () => {
  const decision = decideAutoProbe({
    candidate: { url: "https://cdn.example.com/video.mp4" },
    evidence: publicEvidence,
    pageURL: "https://player.example.com/watch",
    probeable: true,
  });
  assert.deepEqual(decision, { allowed: true, reason: "observed_public" });
});

test("an observed address that turns out private is rejected", () => {
  for (const ip of ["127.0.0.1", "10.1.2.3", "169.254.169.254", "fd00::1", "[::1]"]) {
    const decision = decideAutoProbe({
      candidate: { url: "https://media.internal.example/video.mp4" },
      evidence: { ...publicEvidence, ip },
      pageURL: "https://player.example.com/watch",
      probeable: true,
    });
    assert.equal(decision.allowed, false, `${ip} must block the probe`);
    assert.equal(decision.reason, "private_target");
  }
});

test("a local proxy hop keeps the strict reading for a direct connection", () => {
  // Once the tab has seen any public peer, `ip` is the target's address again,
  // so a loopback peer genuinely means a local target.
  const decision = decideAutoProbe({
    candidate: { url: "https://cdn.example.com/video.mp4" },
    evidence: { ...publicEvidence, ip: "127.0.0.1" },
    pageURL: "https://player.example.com/watch",
    probeable: true,
    peerAddressInformative: true,
  });
  assert.deepEqual(decision, { allowed: false, reason: "private_target" });
});

test("a loopback peer with no public peer in the tab probes on the weaker proof", () => {
  const decision = decideAutoProbe({
    candidate: { url: "https://cdn.example.com/video.mp4" },
    evidence: { ...publicEvidence, ip: "127.0.0.1" },
    pageURL: "https://player.example.com/watch",
    probeable: true,
    peerAddressInformative: false,
  });
  assert.deepEqual(decision, { allowed: true, reason: "observed_via_proxy" });
});

test("a LAN peer is never read as a local proxy", () => {
  // An enterprise proxy on a LAN address and an intranet target look identical
  // in `ip`, so only the loopback hop is forgiven.
  for (const ip of ["192.168.1.10", "10.1.2.3", "172.16.0.9"]) {
    const decision = decideAutoProbe({
      candidate: { url: "https://cdn.example.com/video.mp4" },
      evidence: { ...publicEvidence, ip },
      pageURL: "https://player.example.com/watch",
      probeable: true,
      peerAddressInformative: false,
    });
    assert.equal(decision.allowed, false, `${ip} must stay refused`);
    assert.equal(decision.reason, "private_target");
  }
});

test("the proxy tier never rescues a private host or an unobserved candidate", () => {
  const localTarget = decideAutoProbe({
    candidate: { url: "http://127.0.0.1:6379/dump.mp4" },
    evidence: { ...publicEvidence, url: "http://127.0.0.1:6379/dump.mp4", ip: "127.0.0.1" },
    pageURL: "https://player.example.com/watch",
    probeable: true,
    peerAddressInformative: false,
  });
  assert.deepEqual(localTarget, { allowed: false, reason: "private_target" });

  const unobserved = decideAutoProbe({
    candidate: { url: "https://cdn.example.com/video.mp4" },
    evidence: null,
    pageURL: "https://evil.example/player",
    probeable: true,
    peerAddressInformative: false,
  });
  assert.deepEqual(unobserved, { allowed: false, reason: "unobserved" });

  const unprobeable = decideAutoProbe({
    candidate: { url: "https://cdn.example.com/video.mp4", size: 42 },
    evidence: { ...publicEvidence, ip: "127.0.0.1" },
    pageURL: "https://player.example.com/watch",
    probeable: false,
    peerAddressInformative: false,
  });
  assert.deepEqual(unprobeable, { allowed: false, reason: "not_probeable" });
});

test("a hostname without peer evidence is only probed same-origin", () => {
  const evidence = { ...publicEvidence, ip: null };
  const sameOrigin = decideAutoProbe({
    candidate: { url: "https://player.example.com/media/clip.mp4" },
    evidence,
    pageURL: "https://player.example.com/watch",
    probeable: true,
  });
  assert.deepEqual(sameOrigin, { allowed: true, reason: "same_origin" });

  const crossOrigin = decideAutoProbe({
    candidate: { url: "https://cdn.example.com/video.mp4" },
    evidence,
    pageURL: "https://player.example.com/watch",
    probeable: true,
  });
  assert.equal(crossOrigin.allowed, false);
  assert.equal(crossOrigin.reason, "no_address_evidence");
});

test("candidates excluded by the shape filter stay excluded", () => {
  const decision = decideAutoProbe({
    candidate: { url: "https://cdn.example.com/index.m3u8", size: 1024 },
    evidence: publicEvidence,
    pageURL: "https://player.example.com/watch",
    probeable: false,
  });
  assert.equal(decision.allowed, false);
  assert.equal(decision.reason, "not_probeable");
});

test("non-http and malformed candidates are refused", () => {
  for (const url of ["", "file:///etc/passwd", "blob:https://a.example/x", "not a url"]) {
    const decision = decideAutoProbe({
      candidate: { url },
      evidence: publicEvidence,
      pageURL: "https://player.example.com/watch",
      probeable: true,
    });
    assert.equal(decision.allowed, false, `${url} must not be probed`);
  }
});

test("a decision never echoes the candidate url", () => {
  const decision = decideAutoProbe({
    candidate: { url: "https://cdn.example.com/secret.mp4?token=abc123" },
    evidence: null,
    pageURL: "https://player.example.com/watch",
    probeable: true,
  });
  assert.equal(JSON.stringify(decision).includes("abc123"), false);
});

// -------------------------------------------------------------- evidence ledger

test("evidence is scoped to the tab that produced it", () => {
  const ledger = new ProbeEvidenceLedger();
  ledger.record({ tabId: 1, url: "https://cdn.example.com/a.mp4", ip: "93.184.216.34" });
  assert.equal(ledger.evidenceFor("https://cdn.example.com/a.mp4", { tabId: 1 })?.ip, "93.184.216.34");
  assert.equal(ledger.evidenceFor("https://cdn.example.com/a.mp4", { tabId: 2 }), null);
});

test("navigation invalidates evidence recorded under the old generation", () => {
  const ledger = new ProbeEvidenceLedger();
  ledger.record({ tabId: 1, url: "https://cdn.example.com/a.mp4", ip: "93.184.216.34" });
  assert.equal(ledger.generationOf(1), 0);
  ledger.handleTabNavigated(1);
  assert.equal(ledger.generationOf(1), 1);
  assert.equal(ledger.evidenceFor("https://cdn.example.com/a.mp4", { tabId: 1 }), null);
});

test("evidence expires after the observation window", () => {
  let clock = 1_000;
  const ledger = new ProbeEvidenceLedger({ ttlMs: 500, now: () => clock });
  ledger.record({ tabId: 1, url: "https://cdn.example.com/a.mp4", ip: "93.184.216.34" });
  clock += 400;
  assert.notEqual(ledger.evidenceFor("https://cdn.example.com/a.mp4", { tabId: 1 }), null);
  clock += 200;
  assert.equal(ledger.evidenceFor("https://cdn.example.com/a.mp4", { tabId: 1 }), null);
});

test("closing a tab drops its evidence", () => {
  const ledger = new ProbeEvidenceLedger();
  ledger.record({ tabId: 3, url: "https://cdn.example.com/a.mp4", ip: "93.184.216.34" });
  ledger.handleTabRemoved(3);
  assert.equal(ledger.evidenceFor("https://cdn.example.com/a.mp4", { tabId: 3 }), null);
});

test("only http(s) and known tabs can record evidence", () => {
  const ledger = new ProbeEvidenceLedger();
  assert.equal(ledger.record({ tabId: -1, url: "https://a.example/x.mp4" }), false);
  assert.equal(ledger.record({ url: "https://a.example/x.mp4" }), false);
  assert.equal(ledger.record({ tabId: 1, url: "chrome-extension://x/a.mp4" }), false);
  assert.equal(ledger.record({ tabId: 1, url: "https://a.example/x.mp4" }), true);
});

test("missing peer address is recorded as null rather than a guess", () => {
  const ledger = new ProbeEvidenceLedger();
  ledger.record({ tabId: 1, url: "https://a.example/x.mp4" });
  assert.equal(ledger.evidenceFor("https://a.example/x.mp4", { tabId: 1 }).ip, null);
});

test("the ledger bounds its memory by evicting the oldest evidence", () => {
  const ledger = new ProbeEvidenceLedger({ limit: 2 });
  ledger.record({ tabId: 1, url: "https://a.example/1.mp4", ip: "93.184.216.34" });
  ledger.record({ tabId: 1, url: "https://a.example/2.mp4", ip: "93.184.216.34" });
  ledger.record({ tabId: 1, url: "https://a.example/3.mp4", ip: "93.184.216.34" });
  assert.equal(ledger.evidenceFor("https://a.example/1.mp4", { tabId: 1 }), null);
  assert.notEqual(ledger.evidenceFor("https://a.example/3.mp4", { tabId: 1 }), null);
});

test("a decline belongs to the tab that received it", () => {
  const ledger = new ProbeEvidenceLedger();
  assert.equal(ledger.wasDeclined("https://a.example/x.mp4", { tabId: 1 }), false);
  ledger.markDeclined("https://a.example/x.mp4", { tabId: 1 });
  assert.equal(ledger.wasDeclined("https://a.example/x.mp4", { tabId: 1 }), true);
  assert.equal(
    ledger.wasDeclined("https://a.example/x.mp4", { tabId: 2 }),
    false,
    "another tab's refusal must not suppress this one",
  );
  assert.equal(ledger.clearDeclined("https://a.example/x.mp4", { tabId: 1 }), true);
  assert.equal(ledger.wasDeclined("https://a.example/x.mp4", { tabId: 1 }), false);
  assert.equal(ledger.markDeclined("https://a.example/x.mp4", { tabId: -1 }), false);
});

test("the retry budget accumulates per tab and url", () => {
  const ledger = new ProbeEvidenceLedger();
  assert.equal(ledger.recordFailure("https://a.example/x.mp4", { tabId: 1 }), 1);
  assert.equal(ledger.recordFailure("https://a.example/x.mp4", { tabId: 1 }), 2);
  assert.equal(ledger.failureCount("https://a.example/y.mp4", { tabId: 1 }), 0);
  assert.equal(ledger.failureCount("https://a.example/x.mp4", { tabId: 2 }), 0);
  assert.equal(ledger.clearFailures("https://a.example/x.mp4", { tabId: 1 }), true);
  assert.equal(ledger.failureCount("https://a.example/x.mp4", { tabId: 1 }), 0);
  assert.equal(ledger.recordFailure("https://a.example/x.mp4", { tabId: -1 }), 0);
});

test("navigation and tab close retire the attempt bookkeeping", () => {
  const ledger = new ProbeEvidenceLedger();
  ledger.markDeclined("https://a.example/x.mp4", { tabId: 3 });
  ledger.recordFailure("https://a.example/x.mp4", { tabId: 3 });
  ledger.handleTabNavigated(3);
  assert.equal(ledger.wasDeclined("https://a.example/x.mp4", { tabId: 3 }), false);
  assert.equal(ledger.failureCount("https://a.example/x.mp4", { tabId: 3 }), 0);

  ledger.markDeclined("https://a.example/x.mp4", { tabId: 3 });
  ledger.recordFailure("https://a.example/x.mp4", { tabId: 3 });
  ledger.handleTabRemoved(3);
  assert.equal(ledger.wasDeclined("https://a.example/x.mp4", { tabId: 3 }), false);
  assert.equal(ledger.failureCount("https://a.example/x.mp4", { tabId: 3 }), 0);
});

// --------------------------------------------------- referer context fail-closed

test("isProbeContextValid: Referer 门控与上下文安全校验 (严格 Fail-Closed)", () => {
  const validPage = "https://example.com/watch?v=123";
  const sameReferer = "https://example.com/watch?v=123";
  const diffReferer = "https://example.com/other";

  // 1. 正常合法情况：相同 referer 与 valid http(s) pageUrl
  assert.equal(
    isProbeContextValid({
      currentGen: 1,
      taskGen: 1,
      pageUrl: validPage,
      referer: sameReferer,
    }),
    true,
    "相同合法 referer 与有效 pageUrl 必须放行",
  );

  // 2. 空 referer 场景（必须 Fail-Closed 拦截，绝不能绕过）
  assert.equal(
    isProbeContextValid({
      currentGen: 1,
      taskGen: 1,
      pageUrl: validPage,
      referer: "",
    }),
    false,
    "空字符串 referer 必须拒绝",
  );

  assert.equal(
    isProbeContextValid({
      currentGen: 1,
      taskGen: 1,
      pageUrl: validPage,
      referer: null,
    }),
    false,
    "null referer 必须拒绝",
  );

  assert.equal(
    isProbeContextValid({
      currentGen: 1,
      taskGen: 1,
      pageUrl: validPage,
      referer: undefined,
    }),
    false,
    "undefined referer 必须拒绝",
  );

  // 3. Different referer (cross-page/cross-context must be rejected)
  assert.equal(
    isProbeContextValid({
      currentGen: 1,
      taskGen: 1,
      pageUrl: validPage,
      referer: diffReferer,
    }),
    false,
    "不同 referer 必须拒绝",
  );

  // 4. 非法 pageUrl 上下文（伪协议/非 http(s)）
  for (const invalidPage of [
    "",
    "about:blank",
    "javascript:void(0)",
    "file:///Users/admin/leak",
    "chrome://extensions",
    "data:text/html,<html></html>",
    "not-a-url",
  ]) {
    assert.equal(
      isProbeContextValid({
        currentGen: 1,
        taskGen: 1,
        pageUrl: invalidPage,
        referer: invalidPage,
      }),
      false,
      `非 http(s) pageUrl [${invalidPage}] 必须拒绝`,
    );
  }

  // 5. Generation mismatch
  assert.equal(
    isProbeContextValid({
      currentGen: 2,
      taskGen: 1,
      pageUrl: validPage,
      referer: sameReferer,
    }),
    false,
    "代际不匹配必须拒绝",
  );
});
