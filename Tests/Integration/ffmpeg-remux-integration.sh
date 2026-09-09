#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
FFMPEG_PATH="${MACIDM_FFMPEG_PATH:-$(command -v ffmpeg || true)}"
FFPROBE_PATH="${MACIDM_FFPROBE_PATH:-$(command -v ffprobe || true)}"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macidm-ffmpeg.XXXXXX")"

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

if [[ -z "$FFMPEG_PATH" || -z "$FFPROBE_PATH" ]]; then
  echo "ffmpeg and ffprobe are required for this integration test." >&2
  exit 2
fi

INPUT_PATH="$TEST_DIR/source.mp4"
"$FFMPEG_PATH" -hide_banner -nostdin -loglevel error -y \
  -f lavfi -i "testsrc=size=32x32:rate=2" \
  -f lavfi -i "sine=frequency=1000:sample_rate=44100" \
  -t 1 -c:v mpeg4 -q:v 5 -c:a aac -shortest "$INPUT_PATH"

export MACIDM_FFMPEG_INPUT="file://$INPUT_PATH"
export MACIDM_FFMPEG_PATH="$FFMPEG_PATH"
export MACIDM_FFPROBE_PATH="$FFPROBE_PATH"
export MACIDM_FFMPEG_SHA256="$(shasum -a 256 "$FFMPEG_PATH" | awk '{print $1}')"
export MACIDM_FFPROBE_SHA256="$(shasum -a 256 "$FFPROBE_PATH" | awk '{print $1}')"
export MACIDM_FFMPEG_VERSION="$("$FFMPEG_PATH" -version | head -1)"
export MACIDM_FFPROBE_VERSION="$("$FFPROBE_PATH" -version | head -1)"

SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-/tmp/macidm-swift-cache}" \
CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/macidm-clang-cache}" \
SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/tmp/macidm-swiftpm-cache}" \
swift test --disable-sandbox --filter FFmpegServiceTests

echo "MacIDM FFmpeg remux integration tests passed."
