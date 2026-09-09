#!/bin/bash

set -euo pipefail

# Unified App media-pipeline gate: serves local HLS and DASH fixtures from a
# single HTTP server and runs HLSAppPipelineTests once with both environment
# gates configured. Replaces the former separate app-hls-remux-integration.sh
# and app-dash-merge-integration.sh scripts, which duplicated the toolchain
# probing, server boot, and swift-test invocation.

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
FFMPEG_PATH="${MACIDM_FFMPEG_PATH:-$(command -v ffmpeg || true)}"
FFPROBE_PATH="${MACIDM_FFPROBE_PATH:-$(command -v ffprobe || true)}"
TEST_PORT="${MACIDM_APP_MEDIA_TEST_PORT:-18767}"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macidm-app-media.XXXXXX")"
SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

if [[ -z "$FFMPEG_PATH" || -z "$FFPROBE_PATH" ]]; then
  echo "ffmpeg and ffprobe are required for this integration test." >&2
  exit 2
fi

# HLS fixture: VOD master playlist with one-second segments.
mkdir -p "$TEST_DIR/hls"
"$FFMPEG_PATH" -hide_banner -nostdin -loglevel error \
  -f lavfi -i "testsrc=size=64x64:rate=10" \
  -f lavfi -i "sine=frequency=880:sample_rate=44100" \
  -t 2 -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -f hls -hls_time 1 \
  -hls_playlist_type vod -hls_segment_filename "$TEST_DIR/hls/segment-%03d.ts" \
  "$TEST_DIR/hls/master.m3u8"

# DASH fixture: static MPD with separate video and audio adaptation sets.
mkdir -p "$TEST_DIR/dash"
"$FFMPEG_PATH" -hide_banner -nostdin -loglevel error -y \
  -f lavfi -i "testsrc=size=64x64:rate=10" \
  -f lavfi -i "sine=frequency=880:sample_rate=44100" \
  -t 2 -map 0:v:0 -map 1:a:0 -c:v mpeg4 -q:v 5 -c:a aac \
  -f dash -seg_duration 1 -use_template 1 -use_timeline 1 \
  -adaptation_sets "id=0,streams=v id=1,streams=a" \
  "$TEST_DIR/dash/manifest.mpd"

python3 -m http.server "$TEST_PORT" --bind 127.0.0.1 --directory "$TEST_DIR" &
SERVER_PID="$!"
SERVER_READY=0
for _ in {1..50}; do
  if curl --silent --fail "http://127.0.0.1:$TEST_PORT/hls/master.m3u8" >/dev/null \
    && curl --silent --fail "http://127.0.0.1:$TEST_PORT/dash/manifest.mpd" >/dev/null; then
    SERVER_READY=1
    break
  fi
  sleep 0.1
done
if [[ "$SERVER_READY" != 1 ]]; then
  echo "unable to bind or reach the local media fixture server; rerun outside the sandbox." >&2
  exit 2
fi

export MACIDM_APP_HLS_FIXTURE_URL="http://127.0.0.1:$TEST_PORT/hls/"
export MACIDM_APP_DASH_FIXTURE_URL="http://127.0.0.1:$TEST_PORT/dash/"
export MACIDM_FFMPEG_PATH="$FFMPEG_PATH"
export MACIDM_FFPROBE_PATH="$FFPROBE_PATH"
export MACIDM_FFMPEG_SHA256="$(shasum -a 256 "$FFMPEG_PATH" | awk '{print $1}')"
export MACIDM_FFPROBE_SHA256="$(shasum -a 256 "$FFPROBE_PATH" | awk '{print $1}')"
export MACIDM_FFMPEG_VERSION="$("$FFMPEG_PATH" -version | head -1)"
export MACIDM_FFPROBE_VERSION="$("$FFPROBE_PATH" -version | head -1)"

cd "$ROOT_DIR"
SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-/tmp/macidm-swift-cache}" \
CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/macidm-clang-cache}" \
SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/tmp/macidm-swiftpm-cache}" \
swift test --disable-sandbox --filter HLSAppPipelineTests

echo "MacIDM App HLS remux + DASH merge integration tests passed."
