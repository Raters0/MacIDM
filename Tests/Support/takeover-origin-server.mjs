// Controlled origin server for the takeover E2E suite (spec §10.2).
//
// Serves deterministic files and trigger pages on 127.0.0.1 so every takeover
// case runs without touching a real site. All bytes are fixed patterns, so
// assertions never depend on network variance.

import { createServer } from "node:http";

export const E2E_SECRET_TOKEN = "e2e-secret-token-0123456789";

const OK_BIN_BYTES = 64 * 1024;
const SMALL_BIN_BYTES = 1024;

function patternBuffer(size) {
  const buffer = Buffer.alloc(size);
  for (let index = 0; index < size; index += 1) {
    buffer[index] = index % 251;
  }
  return buffer;
}

const OK_BIN = patternBuffer(OK_BIN_BYTES);
const SMALL_BIN = patternBuffer(SMALL_BIN_BYTES);

function sendAttachment(response, filename, body, { unknownLength = false } = {}) {
  response.writeHead(200, {
    "Content-Type": "application/octet-stream",
    "Content-Disposition": `attachment; filename="${filename}"`,
    ...(unknownLength ? {} : { "Content-Length": String(body.length) }),
  });
  response.end(body);
}

function sendPage(response, title, bodyHtml, headers = {}) {
  response.writeHead(200, { "Content-Type": "text/html; charset=utf-8", ...headers });
  response.end(`<!doctype html><html><head><title>${title}</title></head><body>${bodyHtml}</body></html>`);
}

const TRIGGER = (url, downloadAs) =>
  `<script>const a=document.createElement('a');a.href='${url}';` +
  `${downloadAs ? `a.download='${downloadAs}';` : ""}document.body.appendChild(a);a.click();</script>`;

// Takeover-expected cases trigger on this file: it trickles long enough
// (32 KiB at 256 B/10ms ≈ 1.3 s) for the extension to pause() the in-flight
// download before it completes. Instant files would always fail the pause
// step, which is itself §10.2 case 9 (pause failure) — keep ok.bin instant
// for that and for the skip cases.
const TAKEOVER_FILE = "/files/e2e-takeover.bin";

const PAGES = {
  "/anchor-page.html": (response) =>
    sendPage(response, "anchor", TRIGGER(TAKEOVER_FILE, "e2e-takeover.bin")),
  "/redirect-page.html": (response) =>
    sendPage(response, "redirect", TRIGGER("/redirect", "e2e-takeover.bin")),
  "/signed-page.html": (response) =>
    sendPage(
      response,
      "signed",
      // Token rides on the trickled takeover file so the full takeover flow
      // completes and the redaction assertions see the final storage state.
      TRIGGER(`${TAKEOVER_FILE}?token=${E2E_SECRET_TOKEN}`, "e2e-takeover.bin"),
    ),
  "/instant-page.html": (response) =>
    // 64 KiB arrives instantly: the extension cannot pause() in time, which
    // exercises the §10.2 pause-failure degradation (browser keeps the file).
    sendPage(response, "instant", TRIGGER("/files/ok.bin", "ok.bin")),
  "/cookie-page.html": (response) =>
    sendPage(response, "cookie", TRIGGER(TAKEOVER_FILE, "e2e-takeover.bin"), {
      "Set-Cookie": "macidm_e2e_cookie=authorized-value; Path=/; SameSite=Lax",
    }),
  "/unknown-page.html": (response) =>
    sendPage(response, "unknown", TRIGGER("/files/unknown", "unknown.bin")),
  "/small-page.html": (response) =>
    sendPage(response, "small", TRIGGER("/files/small.bin", "small.bin")),
  // POST the download URL first so the fetch interceptor records it as a
  // body-carrying request; the anchor then GETs the same URL, which takeover
  // must skip to avoid losing the POST body.
  "/post-then-download-page.html": (response) =>
    sendPage(
      response,
      "post-then-download",
      `<script>
        fetch('/files/post.bin', {method:'POST', body:'e2e-payload'})
          .then(() => { const a=document.createElement('a'); a.href='/files/post.bin';
                        document.body.appendChild(a); a.click(); });
      </script>`,
    ),
  "/blob-page.html": (response) =>
    sendPage(
      response,
      "blob",
      `<script>
        fetch('/files/ok.bin').then((res) => res.blob()).then((blob) => {
          const url = URL.createObjectURL(blob);
          const a = document.createElement('a'); a.href = url; a.download = 'from-blob.bin';
          document.body.appendChild(a); a.click();
        });
      </script>`,
    ),
};

export function startOriginServer({ host = "127.0.0.1", port = 0 } = {}) {
  const requests = [];
  const server = createServer((request, response) => {
    const url = new URL(request.url, `http://${request.headers.host}`);
    requests.push({ method: request.method, path: url.pathname, at: Date.now() });

    if (PAGES[url.pathname]) {
      PAGES[url.pathname](response);
      return;
    }
    switch (url.pathname) {
      case "/files/ok.bin":
        sendAttachment(response, "ok.bin", OK_BIN);
        return;
      case "/files/small.bin":
        sendAttachment(response, "small.bin", SMALL_BIN);
        return;
      case "/files/unknown":
        sendAttachment(response, "unknown.bin", OK_BIN, { unknownLength: true });
        return;
      case "/files/e2e-takeover.bin": {
        // Trickle long enough for the extension to pause() mid-flight even
        // under slow service-worker wake-up (64 KiB at 256 B / 20 ms ≈ 5.1 s),
        // with a truthful Content-Length. Takeover cancels the download long
        // before the trickle ends, so cases stay fast.
        const body = patternBuffer(64 * 1024);
        response.writeHead(200, {
          "Content-Type": "application/octet-stream",
          "Content-Disposition": 'attachment; filename="e2e-takeover.bin"',
          "Content-Length": String(body.length),
        });
        let sent = 0;
        const timer = setInterval(() => {
          sent += 256;
          response.write(body.subarray(0, 256));
          if (sent >= body.length) {
            clearInterval(timer);
            response.end();
          }
        }, 20);
        request.on("close", () => clearInterval(timer));
        return;
      }
      case "/files/slow.bin":
        // Trickled attachment used by mid-flow phase tests.
        response.writeHead(200, {
          "Content-Type": "application/octet-stream",
          "Content-Disposition": 'attachment; filename="slow.bin"',
          "Content-Length": String(OK_BIN_BYTES),
        });
        let sent = 0;
        const timer = setInterval(() => {
          sent += 256;
          response.write(OK_BIN.subarray(0, 256));
          if (sent >= OK_BIN_BYTES) {
            clearInterval(timer);
            response.end();
          }
        }, 20);
        request.on("close", () => clearInterval(timer));
        return;
      case "/files/signed.bin":
        sendAttachment(response, "signed.bin", OK_BIN);
        return;
      case "/files/post.bin":
        if (request.method === "POST") {
          response.writeHead(200, { "Content-Type": "application/json" });
          response.end('{"accepted":true}');
        } else {
          sendAttachment(response, "post.bin", OK_BIN);
        }
        return;
      case "/redirect":
        response.writeHead(302, { Location: TAKEOVER_FILE });
        response.end();
        return;
      case "/healthz":
        response.writeHead(200, { "Content-Type": "text/plain" });
        response.end("ok");
        return;
      default:
        response.writeHead(404, { "Content-Type": "text/plain" });
        response.end("not found");
    }
  });

  return new Promise((resolve) => {
    server.listen(port, host, () => {
      const { port: boundPort } = server.address();
      resolve({
        server,
        port: boundPort,
        url: `http://${host}:${boundPort}`,
        requests,
        close: () => new Promise((done) => server.close(done)),
      });
    });
  });
}
