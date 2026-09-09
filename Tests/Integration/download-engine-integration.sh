#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
MACIDM_BIN="${MACIDM_BIN:-$ROOT_DIR/.build/debug/macidm}"
TEST_PORT="${MACIDM_TEST_PORT:-18765}"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macidm-integration.XXXXXX")"
SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

python3 "$ROOT_DIR/Tests/Support/http-fixture-server.py" --port "$TEST_PORT" &
SERVER_PID="$!"

SERVER_READY=0
for _ in {1..50}; do
  if curl --silent --fail --head "http://127.0.0.1:$TEST_PORT/range?size=1" >/dev/null; then
    SERVER_READY=1
    break
  fi
  sleep 0.1
done
if [[ "$SERVER_READY" != 1 ]]; then
  echo "unable to bind or reach the local download fixture server; rerun outside the sandbox." >&2
  exit 2
fi

expected_hash() {
  python3 - "$1" <<'PY'
import hashlib
import sys
size = int(sys.argv[1])
pattern = bytes(range(256))
print(hashlib.sha256((pattern * ((size + 255) // 256))[:size]).hexdigest())
PY
}

run_download() {
  local name="$1"
  local url="$2"
  local parallel="$3"
  mkdir -p "$TEST_DIR/state-$name"
  "$MACIDM_BIN" add "$url" \
    --output "$TEST_DIR/$name.bin" \
    --parallel "$parallel" \
    --foreground \
    --json \
    --state-dir "$TEST_DIR/state-$name" >/dev/null
}

for parallel in 1 2 8 32; do
  run_download "range-$parallel" "http://127.0.0.1:$TEST_PORT/range?size=2097152" "$parallel"
  [[ "$(shasum -a 256 "$TEST_DIR/range-$parallel.bin" | awk '{print $1}')" == "$(expected_hash 2097152)" ]]
done

run_download "single" "http://127.0.0.1:$TEST_PORT/no-range?size=1048576" 8
[[ "$(shasum -a 256 "$TEST_DIR/single.bin" | awk '{print $1}')" == "$(expected_hash 1048576)" ]]

run_download "unknown" "http://127.0.0.1:$TEST_PORT/unknown?size=524288" 8
[[ "$(shasum -a 256 "$TEST_DIR/unknown.bin" | awk '{print $1}')" == "$(expected_hash 524288)" ]]

run_download "signed-foreground" "http://127.0.0.1:$TEST_PORT/range?size=65536&signature=fixture-secret" 4
[[ "$(shasum -a 256 "$TEST_DIR/signed-foreground.bin" | awk '{print $1}')" == "$(expected_hash 65536)" ]]
if rg -n "fixture-secret|signature=|\?" "$TEST_DIR/state-signed-foreground" >/dev/null 2>&1; then
  echo "signed URL leaked into CLI state" >&2
  exit 1
fi
if ! rg -n '"requiresRefetch"[[:space:]]*:[[:space:]]*true' "$TEST_DIR/state-signed-foreground" >/dev/null 2>&1; then
  echo "signed URL state did not record the refetch boundary" >&2
  exit 1
fi

mkdir -p "$TEST_DIR/state-signed-failure"
set +e
"$MACIDM_BIN" add "http://127.0.0.1:$TEST_PORT/bad-range?size=65536&signature=fixture-secret" \
  --output "$TEST_DIR/signed-failure.bin" \
  --parallel 8 \
  --foreground \
  --json \
  --state-dir "$TEST_DIR/state-signed-failure" >/dev/null 2>&1
SIGNED_FAILURE_EXIT=$?
set -e
if [[ "$SIGNED_FAILURE_EXIT" == 0 ]]; then
  echo "signed failure fixture unexpectedly succeeded" >&2
  exit 1
fi
SIGNED_FAILURE_RECORD="$(find "$TEST_DIR/state-signed-failure" -maxdepth 1 -name '*.json' -print -quit)"
SIGNED_FAILURE_ID="${SIGNED_FAILURE_RECORD##*/}"
SIGNED_FAILURE_ID="${SIGNED_FAILURE_ID%.json}"
if "$MACIDM_BIN" resume "$SIGNED_FAILURE_ID" \
  --state-dir "$TEST_DIR/state-signed-failure" >/dev/null 2>&1; then
  echo "CLI resumed a signed URL after process restart" >&2
  exit 1
fi
if ! rg -n '"errorCode"[[:space:]]*:[[:space:]]*"NEEDS_REFETCH"' "$SIGNED_FAILURE_RECORD" >/dev/null 2>&1; then
  echo "failed signed URL was not converted to NEEDS_REFETCH" >&2
  exit 1
fi

mkdir -p "$TEST_DIR/state-signed-background"
if "$MACIDM_BIN" add "http://127.0.0.1:$TEST_PORT/range?size=65536&signature=fixture-secret" \
  --output "$TEST_DIR/signed-background.bin" \
  --state-dir "$TEST_DIR/state-signed-background" >/dev/null 2>&1; then
  echo "background signed URL was accepted" >&2
  exit 1
fi
if rg -n "fixture-secret|signature=" "$TEST_DIR/state-signed-background" >/dev/null 2>&1; then
  echo "rejected signed URL left a state record" >&2
  exit 1
fi

mkdir -p "$TEST_DIR/state-bad"
if "$MACIDM_BIN" add "http://127.0.0.1:$TEST_PORT/bad-range?size=65536" \
  --output "$TEST_DIR/bad.bin" \
  --parallel 8 \
  --foreground \
  --json \
  --state-dir "$TEST_DIR/state-bad" >/dev/null 2>&1; then
  echo "bad Content-Range unexpectedly succeeded" >&2
  exit 1
fi
[[ ! -e "$TEST_DIR/bad.bin" ]]

echo "MacIDM integration tests passed."
