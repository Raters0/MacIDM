// Stub native messaging host for the takeover E2E suite.
//
// Speaks the Chrome native-messaging framing (uint32 length prefix + UTF-8
// JSON on stdio) and stands in for the real MacIDM host so the E2E suite can
// exercise the extension's takeover flow without launching the GUI App.
//
// Control protocol (files inside the control directory given as argv[2]):
//   behavior.json   - scripted replies, re-read before every message. Shape:
//     {
//       "rules": {
//         "download.create": { "mode": "ready", "times": 1,
//                              "taskId": "e2e-task-1", "takeoverToken": "e2e-token-1" },
//         "download.enqueue": { "mode": "pending" },
//         "download.browserCancelled": { "mode": "exit" }
//       }
//     }
//     Modes: ready | pending | accepted | pong | error | timeout | exit.
//     `times` limits how many matching requests a rule covers; afterwards the
//     built-in default applies. `error` uses errorCode/retryable; `delayMs`
//     defers any mode.
//   messages.jsonl  - one JSON object per inbound request (seq, type, request).
//   host-lifecycle.jsonl - {event: "start"|"exit", pid} so the driver can
//     observe host respawns (the host-restart E2E case).
//
// The stub intentionally records full URLs: it stands on the App side of the
// trust boundary, where the spec requires complete URLs. It is never read as
// evidence for the redaction case, which only inspects extension-side storage
// and console output.

import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";

const controlDir = process.argv[2];
if (!controlDir) {
  console.error("usage: takeover-stub-native-host.mjs <control-dir>");
  process.exit(2);
}
const messagesPath = `${controlDir}/messages.jsonl`;
const lifecyclePath = `${controlDir}/host-lifecycle.jsonl`;
const behaviorPath = `${controlDir}/behavior.json`;

let seq = 0;
let taskIdCounter = 0;

function appendLine(path, entry) {
  appendFileSync(path, `${JSON.stringify(entry)}\n`);
}

function readBehavior() {
  try {
    const parsed = JSON.parse(readFileSync(behaviorPath, "utf8"));
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch {
    return {};
  }
}

// Built-in replies mirror the real App's happy path (non-interactive create,
// interactive pending, cancellation receipts) so an empty behavior.json means
// "act like a healthy App".
const DEFAULT_MODES = {
  ping: "pong",
  "download.create": "ready",
  "download.enqueue": "pending",
  "download.abandon": "accepted",
  "download.browserCancelled": "accepted",
  "download.browserCancelFailed": "accepted",
};

function defaultModeFor(type) {
  return DEFAULT_MODES[type] ?? "error-unknown-type";
}

function buildReply(mode, request) {
  // Every reply must echo protocolVersion and requestId — the extension's
  // validateResponse rejects responses whose requestId does not match.
  const envelope = { protocolVersion: 1, requestId: request?.requestId };
  if (mode === "pong") {
    return { ...envelope, status: "ok", type: "pong" };
  }
  if (mode === "ready") {
    taskIdCounter += 1;
    return {
      ...envelope,
      status: "ok",
      type: "download.readyForTakeover",
      payload: { taskId: `e2e-task-${taskIdCounter}`, takeoverToken: `e2e-token-${taskIdCounter}` },
    };
  }
  if (mode === "pending") {
    return { ...envelope, status: "ok", type: "download.confirmationPending" };
  }
  if (mode === "accepted") {
    return { ...envelope, status: "ok", type: "download.accepted" };
  }
  return { ...envelope, status: "error", error: { code: "APP_REJECTED", message: "e2e stub: unsupported request type" } };
}

// Pop the scripted rule for this request type, honouring `times`: a rule with
// times > 1 stays with one use removed, otherwise it is consumed. The updated
// behavior file is written back so a respawned stub host (host-restart case)
// does not re-apply already-used rules.
function consumeRule(type) {
  const behavior = readBehavior();
  const rules = behavior.rules && typeof behavior.rules === "object" ? { ...behavior.rules } : {};
  const rule = rules[type] && typeof rules[type] === "object" ? { ...rules[type] } : null;
  if (!rule) return null;
  if (Number.isInteger(rule.times) && rule.times > 1) {
    rule.times -= 1;
    rules[type] = rule;
  } else {
    delete rules[type];
  }
  writeFileSync(behaviorPath, `${JSON.stringify({ ...behavior, rules }, null, 2)}\n`);
  return rule;
}

function applyRule(type, request) {
  const rule = consumeRule(type);
  const mode = rule?.mode ?? defaultModeFor(type);
  const respond = (modeToApply) => {
    if (modeToApply === "timeout") return null;
    if (modeToApply === "error") {
      return {
        ...{ protocolVersion: 1, requestId: request?.requestId },
        status: "error",
        error: {
          code: typeof rule?.errorCode === "string" ? rule.errorCode : "APP_REJECTED",
          message: "e2e stub scripted failure",
          retryable: rule?.retryable === true,
        },
      };
    }
    if (modeToApply === "exit") {
      appendLine(lifecyclePath, { event: "exit", pid: process.pid, reason: "scripted" });
      process.exit(0);
    }
    return buildReply(modeToApply, request);
  };
  if (rule?.delayMs && Number.isSafeInteger(rule.delayMs) && rule.delayMs > 0) {
    const followUpMode = mode === "delay" ? rule.then ?? defaultModeFor(type) : mode;
    setTimeout(() => {
      const reply = respond(followUpMode);
      if (reply) send(reply);
    }, rule.delayMs);
    return;
  }
  const reply = respond(mode);
  if (reply) send(reply);
}

// --- Native messaging framing -------------------------------------------------

const pendingLength = Buffer.alloc(4);
let pendingLengthBytes = 0;
let pendingBody = null;
let pendingBodyBytes = 0;

function tryReadMessage() {
  while (true) {
    if (pendingBody === null) {
      if (pendingLengthBytes < 4) return;
      const length = pendingLength.readUInt32LE(0);
      if (length === 0 || length > 4 * 1024 * 1024) {
        process.exit(1);
      }
      pendingBody = Buffer.alloc(length);
      pendingBodyBytes = 0;
    }
    if (pendingBodyBytes < pendingBody.length) return;
    const request = JSON.parse(pendingBody.toString("utf8"));
    pendingLengthBytes = 0;
    pendingBody = null;
    seq += 1;
    appendLine(messagesPath, {
      seq,
      receivedAt: new Date().toISOString(),
      type: request?.type,
      requestId: request?.requestId,
      idempotencyKey: request?.idempotencyKey,
      request,
    });
    applyRule(request?.type, request);
  }
}

process.stdin.on("data", (chunk) => {
  let offset = 0;
  while (offset < chunk.length) {
    if (pendingBody === null && pendingLengthBytes < 4) {
      const copied = chunk.copy(pendingLength, pendingLengthBytes, offset, offset + (4 - pendingLengthBytes));
      pendingLengthBytes += copied;
      offset += copied;
    } else if (pendingBody !== null) {
      const copied = chunk.copy(pendingBody, pendingBodyBytes, offset, offset + (pendingBody.length - pendingBodyBytes));
      pendingBodyBytes += copied;
      offset += copied;
    }
    tryReadMessage();
  }
});

const outboundHeader = Buffer.alloc(4);
function send(message) {
  const body = Buffer.from(JSON.stringify(message), "utf8");
  outboundHeader.writeUInt32LE(body.length, 0);
  process.stdout.write(outboundHeader);
  process.stdout.write(body);
}

appendLine(lifecyclePath, { event: "start", pid: process.pid });
appendLine(messagesPath, { seq: 0, receivedAt: new Date().toISOString(), type: "e2e.hostStarted", request: null });
process.stdin.resume();
process.on("exit", () => {
  appendLine(lifecyclePath, { event: "exit", pid: process.pid, reason: "stream-end" });
});
