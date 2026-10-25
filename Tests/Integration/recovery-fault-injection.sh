#!/bin/bash
# Recovery fault-injection matrix (product-spec §8.2 "引擎可靠性"):
#   S1  kill -9 mid-download, then resume  → final SHA-256 matches the source
#   S2  kill -9 + truncate the partial file, then resume → SHA still matches
#   S3  kill -9 + wipe checkpoint state, then resume → SHA still matches
#   S4  server killed mid-download, server restarted, then resume → SHA matches
#   S5  disk-full volume → the download must fail/pause without marking the
#       incomplete file as a finished artifact (skipped when hdiutil is
#       unavailable in the sandbox)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
MACIDM_BIN="${MACIDM_BIN:-$ROOT_DIR/.build/debug/macidm}"
TEST_PORT="${MACIDM_FAULT_TEST_PORT:-18770}"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macidm-faults.XXXXXX")"
SERVER_PID=""

cleanup() {
  if [[ -n "${DOWNLOAD_PID:-}" ]]; then
    kill -9 "$DOWNLOAD_PID" 2>/dev/null || true
  fi
  if [[ -n "$SERVER_PID" ]]; then
    kill -9 "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  if [[ -n "${ATTACH_DIR:-}" ]]; then
    hdiutil detach "$ATTACH_DIR" -quiet >/dev/null 2>&1 || true
  fi
  if [[ "${MACIDM_FAULT_KEEP:-0}" == "1" ]]; then
    echo "kept fault-injection workspace at $TEST_DIR (MACIDM_FAULT_KEEP=1)" >&2
    return
  fi
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

start_server() {
  python3 "$ROOT_DIR/Tests/Support/http-fixture-server.py" --port "$TEST_PORT" &
  SERVER_PID=$!
  for _ in {1..50}; do
    if curl --silent --fail "http://127.0.0.1:$TEST_PORT/range?size=1" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  echo "unable to reach the fixture server; rerun outside the sandbox." >&2
  exit 2
}

expected_hash() {
  python3 - "$1" <<'PY'
import hashlib
import sys
size = int(sys.argv[1])
pattern = bytes(range(256))
print(hashlib.sha256((pattern * ((size + 255) // 256))[:size]).hexdigest())
PY
}

# Start a slow 8 MB download (16 KB chunks × 15 ms ≈ 7.7 s on a single
# connection) in the background and return once bytes are on disk so the kill
# lands mid-flight. parallel=1 keeps progress linear and predictable.
start_slow_download() {
  local name="$1"
  mkdir -p "$TEST_DIR/state-$name"
  "$MACIDM_BIN" add "http://127.0.0.1:$TEST_PORT/slow/8388608" \
    --output "$TEST_DIR/$name.bin" \
    --parallel 1 \
    --foreground \
    --state-dir "$TEST_DIR/state-$name" >/dev/null 2>&1 &
  DOWNLOAD_PID=$!
  # The engine writes to a hidden .macidm.download temp file and only renames
  # to the final destination at completion — watch the temp file so the kill
  # lands mid-flight, never on a finished task.
  for _ in {1..200}; do
    if find "$TEST_DIR" -maxdepth 1 -name ".*.macidm.download" -size +1M -print -quit 2>/dev/null | grep -q .; then
      return 0
    fi
    sleep 0.1
  done
  echo "download $name never got mid-flight; slow fixture too fast?" >&2
  return 1
}

assert_incomplete() {
  local name="$1"
  local status
  status="$(python3 -c "
import json, pathlib, sys
record = next(pathlib.Path('$TEST_DIR/state-$name').glob('*.json'))
print(json.loads(record.read_text()).get('status', ''))" 2>/dev/null || true)"
  if [[ "$status" == "completed" ]]; then
    echo "scene $name: download already completed before the fault landed" >&2
    exit 1
  fi
}

task_id() {
  find "$TEST_DIR/state-$1" -maxdepth 1 -name '*.json' -print -quit | xargs -I{} basename {} .json
}

# `macidm resume` spawns a background worker; the artifact is preallocated, so
# poll the task record's status instead of the file size.
await_task() {
  local name="$1"
  local state_file
  state_file="$(find "$TEST_DIR/state-$name" -maxdepth 1 -name '*.json' -print -quit)"
  for _ in {1..300}; do
    local status
    status="$(python3 -c "
import json, pathlib, sys
record = pathlib.Path('$state_file')
if not record.exists():
    sys.exit(1)
print(json.loads(record.read_text()).get('status', ''))" 2>/dev/null || true)"
    if [[ "$status" == "completed" ]]; then
      return 0
    fi
    if [[ "$status" == "failed" || "$status" == "storageError" || "$status" == "needsRestart" ]]; then
      echo "recovery download $name ended with status $status" >&2
      return 1
    fi
    sleep 0.5
  done
  echo "recovery download $name did not complete within timeout" >&2
  return 1
}

resume_task() {
  "$MACIDM_BIN" resume "$(task_id "$1")" --state-dir "$TEST_DIR/state-$1" >/dev/null 2>&1
}

verify_sha() {
  local name="$1" size="$2"
  local actual
  actual="$(shasum -a 256 "$TEST_DIR/$name.bin" | awk '{print $1}')"
  if [[ "$actual" != "$(expected_hash "$size")" ]]; then
    echo "FAIL $name: SHA-256 mismatch after recovery" >&2
    exit 1
  fi
  echo "PASS $name"
}

start_server
SIZE=8388608

# S1: kill -9 mid-download, resume.
start_slow_download "kill-resume"
kill -9 "$DOWNLOAD_PID" 2>/dev/null || true
wait "$DOWNLOAD_PID" 2>/dev/null || true
DOWNLOAD_PID=""
assert_incomplete "kill-resume"
resume_task "kill-resume"
await_task "kill-resume"
verify_sha "kill-resume" "$SIZE"

# S2: kill -9 + truncate the partial file, resume must still heal.
start_slow_download "truncate-resume"
kill -9 "$DOWNLOAD_PID" 2>/dev/null || true
wait "$DOWNLOAD_PID" 2>/dev/null || true
DOWNLOAD_PID=""
assert_incomplete "truncate-resume"
partial_file=$(find "$TEST_DIR" -maxdepth 1 -name ".*.macidm.download" -print -quit)
partial_size=$(stat -f%z "$partial_file")
truncate -s $((partial_size / 2)) "$partial_file"
resume_task "truncate-resume"
await_task "truncate-resume"
verify_sha "truncate-resume" "$SIZE"

# S3: kill -9 + wipe checkpoint/sidecar state, resume restarts cleanly.
start_slow_download "wipe-state-resume"
kill -9 "$DOWNLOAD_PID" 2>/dev/null || true
wait "$DOWNLOAD_PID" 2>/dev/null || true
DOWNLOAD_PID=""
assert_incomplete "wipe-state-resume"
find "$TEST_DIR/state-wipe-state-resume" -type f ! -name '*.json' -delete 2>/dev/null || true
resume_task "wipe-state-resume"
await_task "wipe-state-resume"
verify_sha "wipe-state-resume" "$SIZE"

# S4: server dies mid-download; restart the server, then resume.
start_slow_download "server-restart-resume"
kill -9 "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
kill -9 "$DOWNLOAD_PID" 2>/dev/null || true
wait "$DOWNLOAD_PID" 2>/dev/null || true
DOWNLOAD_PID=""
assert_incomplete "server-restart-resume"
sleep 0.3
start_server
resume_task "server-restart-resume"
await_task "server-restart-resume"
verify_sha "server-restart-resume" "$SIZE"

# S5: disk-full volume — the engine must not leave a "complete" artifact.
if command -v hdiutil >/dev/null 2>&1; then
  DMG="$TEST_DIR/tiny.dmg"
  ATTACH_DIR=""
  if hdiutil create -size 3m -fs APFS -volname macidm-fault "$DMG" -ov -quiet >/dev/null 2>&1 \
    && ATTACH_DIR="$(hdiutil attach "$DMG" -mountpoint "$TEST_DIR/vol" -nobrowse -quiet 2>/dev/null && echo "$TEST_DIR/vol")"; then
    mkdir -p "$TEST_DIR/state-diskfull"
    set +e
    "$MACIDM_BIN" add "http://127.0.0.1:$TEST_PORT/range?size=8388608" \
      --output "$TEST_DIR/vol/diskfull.bin" \
      --parallel 2 \
      --foreground \
      --state-dir "$TEST_DIR/state-diskfull" >/dev/null 2>&1
    DISKFULL_EXIT=$?
    set -e
    recorded_status="$(python3 -c "
import json, pathlib
statuses = [json.loads(p.read_text()).get('status', '') for p in pathlib.Path('$TEST_DIR/state-diskfull').glob('*.json')]
print(','.join(statuses))")"
    if [[ "$DISKFULL_EXIT" == "0" || "$recorded_status" == *completed* ]]; then
      echo "FAIL disk-full: download reported success on a 3 MB volume (exit=$DISKFULL_EXIT status=$recorded_status)" >&2
      exit 1
    fi
    echo "PASS disk-full (exit=$DISKFULL_EXIT status=$recorded_status)"
  else
    echo "SKIP disk-full: could not attach a scratch volume in this environment"
  fi
else
  echo "SKIP disk-full: hdiutil unavailable"
fi

echo "MacIDM recovery fault-injection matrix passed."
