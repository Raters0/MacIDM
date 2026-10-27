#!/bin/bash

# Render the README interface previews (Resources/Design/readme-demo/*.html)
# into animated GIFs under README-assets/, in Chinese and English.
#
# Each preview draws a deterministic frame from a time value
# (window.renderAt), so frames are rendered one by one in an ego-browser
# page at 2x density and assembled with FFmpeg; no screen recording is
# involved. The output is an illustration of the real UI and the README
# labels it as an interface preview.
#
# Requirements: ego-browser (Ego Lite), ffmpeg, python3.
# Usage: scripts/render-readme-demos.sh [demo ...]
#   demo: page-sniff | browser-popup | app-overview (default: all)

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
output_directory="$repository_root/README-assets"
port="${MACIDM_DEMO_PORT:-8766}"
# Every preview registers fps 10 (demo-kit.js registerScene default).
frames_per_second=10
demos=("$@")
if [ ${#demos[@]} -eq 0 ]; then
  demos=(page-sniff browser-popup app-overview)
fi

for tool in ego-browser ffmpeg python3; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "[render-readme-demos] missing required tool: $tool" >&2
    exit 1
  }
done

work_directory="$(mktemp -d "${TMPDIR:-/tmp}/macidm-readme-demos.XXXXXX")"
server_pid=""
cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$work_directory"
}
trap cleanup EXIT

python3 -m http.server "$port" --bind 127.0.0.1 --directory "$repository_root" >/dev/null 2>&1 &
server_pid=$!
for _ in $(seq 1 50); do
  curl -sf -o /dev/null "http://127.0.0.1:$port/Resources/Design/readme-demo/demo-kit.js" && break
  sleep 0.1
done

# Output width per demo (frames render at 2x and are downscaled once).
output_width() {
  case "$1" in
    page-sniff) echo 1024 ;;
    browser-popup) echo 760 ;;
    app-overview) echo 1280 ;;
    *) echo "[render-readme-demos] unknown demo: $1" >&2; exit 1 ;;
  esac
}

for demo in "${demos[@]}"; do
  output_width "$demo" >/dev/null
  for language in zh en; do
    frame_directory="$work_directory/$demo-$language"
    mkdir -p "$frame_directory"
    echo "[render-readme-demos] rendering $demo ($language)" >&2
    ego-browser nodejs <<EOF
const task = await taskSpace("MacIDM README demo render");
const page = task.page("p1");
await page.goto("http://127.0.0.1:$port/Resources/Design/readme-demo/$demo.html?static&lang=$language");
await page.waitForFunction(() => window.DEMO && typeof window.renderAt === "function", undefined, { timeout: 15000 });
const demo = await page.evaluate(() => window.DEMO);
await page.cdp("Emulation.setDeviceMetricsOverride", {
  width: demo.width, height: demo.height, deviceScaleFactor: 2, mobile: false,
});
await page.evaluate(() => document.fonts.ready.then(() => true));
await page.waitForFunction(() => [...document.images].every((image) => image.complete), undefined, { timeout: 15000 });
const frames = Math.round(demo.duration * demo.fps);
for (let index = 0; index < frames; index += 1) {
  await page.evaluate((time) => window.renderAt(time), index / demo.fps);
  await page.screenshot({ path: "$frame_directory/" + String(index).padStart(4, "0") + ".png" });
}
await page.cdp("Emulation.clearDeviceMetricsOverride", {});
console.log(JSON.stringify({ frames }));
EOF
    suffix=""
    [ "$language" = en ] && suffix="-en"
    width="$(output_width "$demo")"
    ffmpeg -v error -y -framerate "$frames_per_second" -i "$frame_directory/%04d.png" \
      -vf "scale=${width}:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=192:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" \
      -loop 0 "$output_directory/$demo$suffix.gif"
    echo "[render-readme-demos] wrote README-assets/$demo$suffix.gif ($(du -h "$output_directory/$demo$suffix.gif" | cut -f1))" >&2
  done
done

# One task space serves every render above; close it once at the end.
ego-browser nodejs <<'EOF'
const task = await taskSpace("MacIDM README demo render");
await task.finish({ keep: [] });
EOF
