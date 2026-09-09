#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_PORT="${MACIDM_HLS_TEST_PORT:-18766}"
SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

python3 "$ROOT_DIR/Tests/Support/http-fixture-server.py" --port "$TEST_PORT" &
SERVER_PID="$!"

SERVER_READY=0
for _ in {1..50}; do
  if curl --silent --fail "http://127.0.0.1:$TEST_PORT/hls/vod.m3u8" >/dev/null; then
    SERVER_READY=1
    break
  fi
  sleep 0.1
done
if [[ "$SERVER_READY" != 1 ]]; then
  echo "unable to bind or reach the local HLS fixture server; rerun outside the sandbox." >&2
  exit 2
fi

MACIDM_HLS_FIXTURE_URL="http://127.0.0.1:$TEST_PORT/" \
SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-/tmp/macidm-swift-cache}" \
CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/macidm-clang-cache}" \
SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/tmp/macidm-swiftpm-cache}" \
swift test --disable-sandbox --filter HLSURLSessionIntegrationTests

echo "MacIDM HLS integration tests passed."
