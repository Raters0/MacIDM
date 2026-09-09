# MacIDM Local Agent HTTP API

The MacIDM desktop app exposes a lightweight HTTP API on `127.0.0.1:7831` so scripts, automation tools, and AI agents can read app state and control download tasks without screenshots or UI automation. The service is local-only and is not exposed to the network.

There are also two equivalent read-only paths:

- `~/Library/Application Support/MacIDM/status.json`: an app-state snapshot, written at most once per second after a state change;
- `macidm app-status`, `macidm logs`, and `macidm watch`: CLI commands that read the same snapshot.

## Read-only endpoints (GET)

| Path | Token | Description |
| --- | --- | --- |
| `GET /health` | Not required | Liveness check; returns `{ok, version}` |
| `GET /status` | Required | Full state: version, bridge, yt-dlp, FFmpeg, tasks, and recent logs |
| `GET /tasks` | Required | Task list with IDs, status, filenames, byte progress, speed, and errors |
| `GET /logs` | Required | The 20 most recent log entries |
| `GET /settings` | Required | Current settings snapshot |

Except for `/health`, read endpoints can expose task filenames, error text, and recent logs. They therefore require the same `X-MacIDM-Token` as control endpoints. Local automation may read the token from the owner-only token file; it should never print or persist the token.

## Control endpoints

Every control endpoint requires the random token generated for the current app launch:

```text
X-MacIDM-Token: <token>
```

The token is stored at `~/Library/Application Support/MacIDM/agent-token` with mode `0600` and is regenerated on every app launch. Missing or invalid tokens return `401`. Web pages cannot read this file, and the custom header triggers a CORS preflight, so remote pages cannot call control endpoints.

All control endpoints return a common JSON shape:

```json
{
  "ok": true,
  "message": "optional",
  "taskID": "optional",
  "destination": "optional",
  "task": {},
  "settings": {}
}
```

### Add a download

```bash
TOKEN=$(cat "$HOME/Library/Application Support/MacIDM/agent-token")
curl -X POST http://127.0.0.1:7831/downloads -H "X-MacIDM-Token: $TOKEN" -H "Content-Type: application/json" -d '{"url":"https://example.com/video.mp4","filename":"optional","directory":"optional","start":true,"parallel":8}'
```

- `url` (required): an HTTP(S) URL; `.m3u8` and `.mpd` URLs are detected as HLS/DASH automatically;
- `filename` and `directory`: when omitted, the filename is inferred from the URL and the default download directory is used;
- `start`: when omitted, follows the app automatic-start setting;
- `parallel`: per-task concurrent request count from 1 to 64; when omitted, follows the app setting;
- the response `taskID` can be used for later control; `destination` is the final save path.

### Control a task

```bash
TOKEN=$(cat "$HOME/Library/Application Support/MacIDM/agent-token")
curl -X POST -H "X-MacIDM-Token: $TOKEN" http://127.0.0.1:7831/tasks/<taskID>/pause
curl -X POST -H "X-MacIDM-Token: $TOKEN" http://127.0.0.1:7831/tasks/<taskID>/resume
curl -X POST -H "X-MacIDM-Token: $TOKEN" http://127.0.0.1:7831/tasks/<taskID>/cancel
curl -X DELETE -H "X-MacIDM-Token: $TOKEN" "http://127.0.0.1:7831/tasks/<taskID>?deleteFile=true"
```

Deletion follows the app keep-in-history setting by default. `deleteFile=true` also removes the downloaded file.

### Update settings (supported subset)

```bash
TOKEN=$(cat "$HOME/Library/Application Support/MacIDM/agent-token")
curl -X POST http://127.0.0.1:7831/settings -H "X-MacIDM-Token: $TOKEN" -H "Content-Type: application/json" -d '{"speedLimitKBps":2048,"simultaneousDownloads":5}'
```

Supported keys are `downloadDirectory`, `maximumParallelRequests`, `simultaneousDownloads`, `speedLimitKBps`, `autoStartDownloads`, `organizeByCategory`, `archiveOnDelete`, `notificationSoundsEnabled`, `clipboardAutoDetect`, and `ytdlpAutoCheckUpdates`. Unknown keys are ignored.

```bash
TOKEN=$(cat "$HOME/Library/Application Support/MacIDM/agent-token")
curl -s -H "X-MacIDM-Token: $TOKEN" http://127.0.0.1:7831/tasks
```

## Typical agent polling flow

1. Call `GET /health` to confirm that the app is running. It is the only endpoint that does not require a token.
2. Submit a task with `POST /downloads` and record the returned `taskID`.
3. Poll `GET /tasks`. Calculate progress with `receivedBytes / totalBytes`; `speed` is bytes per second. Typical status values include `queued`, `downloading`, `paused`, `completed`, `failed`, and `cancelled`.
4. After completion, use `destination` to locate the final file.

## Security boundaries

- The service listens only on the loopback interface; other devices on the local network cannot access it.
- Control endpoints and every read endpoint except `/health` require a random per-launch `X-MacIDM-Token` stored in Application Support with mode `0600`. Requests without a token return `401`.
- The token is configured before the listener starts. If the service ever has no usable token, every endpoint except `/health` returns `503` rather than opening an unprotected window.
- `Host` must be a loopback name (`127.0.0.1`, `localhost`, or `::1`). If an `Origin` header is present, it must also be a loopback origin; otherwise the request returns `400`. This blocks DNS-rebinding attempts where a remote page maps its own domain to `127.0.0.1`.
- At most 16 connections are accepted concurrently. Each connection has a 15-second deadline that remains active until response bytes are written, preventing slow readers from bypassing the limit. Each source is limited to 40 requests per 10 seconds; excess requests return `429`.
- Request bodies are limited to 1 MB; larger bodies return `413`.
