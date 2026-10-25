#!/bin/bash
# DASH six fixed-sample integration gate (product-spec §8.2: DASH 六组固定样本).
#
# Generates deterministic DASH fixtures with FFmpeg (lavfi sources), serves
# them locally, downloads each sample through `macidm`, and verifies the merged
# output with ffprobe: duration ≈ 4 s and both audio + video streams present.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
MACIDM_BIN="${MACIDM_BIN:-$ROOT_DIR/.build/debug/macidm}"
TEST_PORT="${MACIDM_DASH_TEST_PORT:-18768}"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macidm-dash.XXXXXX")"
SERVER_PID=""

if ! command -v ffmpeg >/dev/null 2>&1 || ! command -v ffprobe >/dev/null 2>&1; then
  echo "SKIP: ffmpeg/ffprobe not installed; DASH integration gate requires the FFmpeg toolchain."
  exit 0
fi

cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

python3 "$ROOT_DIR/Tests/Support/generate-dash-fixtures.py" --out "$TEST_DIR/fixtures"
python3 "$ROOT_DIR/Tests/Support/dash-fixture-server.py" --root "$TEST_DIR/fixtures" --port "$TEST_PORT" &
SERVER_PID=$!

SERVER_READY=0
for _ in {1..50}; do
  if curl --silent --fail "http://127.0.0.1:$TEST_PORT/number.mpd" >/dev/null; then
    SERVER_READY=1
    break
  fi
  sleep 0.1
done
if [[ "$SERVER_READY" != 1 ]]; then
  echo "unable to bind or reach the local DASH fixture server; rerun outside the sandbox." >&2
  exit 2
fi

SAMPLES=(number time list multirep adaptation single-segment)
FAILED=()

for sample in "${SAMPLES[@]}"; do
  out="$TEST_DIR/out-$sample.mp4"
  state_dir="$TEST_DIR/state-$sample"
  mkdir -p "$state_dir"
  if ! "$MACIDM_BIN" add \
      "http://127.0.0.1:$TEST_PORT/$sample.mpd" \
      --output "$out" --foreground --state-dir "$state_dir" >/dev/null 2>&1; then
    FAILED+=("$sample (download)")
    continue
  fi
  # Duration must be ~4 s and both streams must survive the merge. ffprobe
  # prints stream lines first and the format duration last (nokey output).
  probe=$(ffprobe -v error -show_entries format=duration -show_entries stream=codec_type \
    -of default=noprint_wrappers=1:nokey=1 "$out" 2>/dev/null || true)
  duration=$(printf '%s\n' "$probe" | grep -E '^[0-9]+(\.[0-9]+)?$' | head -1)
  streams=$(printf '%s\n' "$probe" | grep -E '^(video|audio)$' | sort | uniq | tr '\n' ',')
  if ! python3 -c "
import sys
try:
    duration = float('$duration')
except ValueError:
    sys.exit(1)
sys.exit(0 if 3.4 <= duration <= 4.6 else 1)"; then
    FAILED+=("$sample (duration=$duration)")
    continue
  fi
  if [[ "$streams" != *"video"* || "$streams" != *"audio"* ]]; then
    FAILED+=("$sample (streams=$streams)")
    continue
  fi
  echo "PASS $sample (duration=${duration}s streams=$streams)"
done

if [[ "${#FAILED[@]}" -gt 0 ]]; then
  echo "DASH integration FAILED for: ${FAILED[*]}" >&2
  exit 1
fi
echo "MacIDM DASH six fixed-sample integration passed."
