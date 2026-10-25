#!/bin/bash
# Throughput / weak-bandwidth benchmark (product-spec §8.2 "性能" gate).
#
# Downloads a deterministic fixture of MACIDM_BENCH_SIZE bytes (default: the
# spec profile's 1 GiB) MACIDM_BENCH_RUNS times (default: 5) per parallelism
# config over loopback, then reports per-config wall-time percentiles
# (P10/median/P90), throughput, and the multi-connection vs single-connection
# median ratio. Fixed-hardware numbers only: do not present results as
# real-world site speeds (spec §9).
#
# Env:
#   MACIDM_BENCH_SIZE   bytes per download      (default 1073741824)
#   MACIDM_BENCH_RUNS   runs per config         (default 5)
#   MACIDM_BENCH_PARALLEL  configs to sweep     (default "1 8")
#   MACIDM_BENCH_REPORT report output path      (default: none, stdout only)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
MACIDM_BIN="${MACIDM_BIN:-$ROOT_DIR/.build/debug/macidm}"
TEST_PORT="${MACIDM_BENCH_PORT:-18774}"
SIZE="${MACIDM_BENCH_SIZE:-1073741824}"
RUNS="${MACIDM_BENCH_RUNS:-5}"
CONFIGS=(${MACIDM_BENCH_PARALLEL:-1 8})
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macidm-bench.XXXXXX")"
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
SERVER_PID=$!
for _ in {1..50}; do
  if curl --silent --fail --head "http://127.0.0.1:$TEST_PORT/range?size=1" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

MEDIANS_PAIRS=""
for parallel in "${CONFIGS[@]}"; do
  times=()
  for run in $(seq 1 "$RUNS"); do
    mkdir -p "$TEST_DIR/state-$parallel-$run"
    start=$(python3 -c 'import time; print(time.time())')
    "$MACIDM_BIN" add "http://127.0.0.1:$TEST_PORT/range?size=$SIZE" \
      --output "$TEST_DIR/out-$parallel-$run.bin" \
      --parallel "$parallel" \
      --foreground \
      --state-dir "$TEST_DIR/state-$parallel-$run" >/dev/null 2>&1
    end=$(python3 -c 'import time; print(time.time())')
    times+=("$(python3 -c "print(f'{$end - $start:.4f}')")")
  done
  stats=$(python3 - "$SIZE" "${times[@]}" <<'PY'
import statistics
import sys

size = int(sys.argv[1])
times = sorted(float(value) for value in sys.argv[2:])


def percentile(values, fraction):
    index = min(len(values) - 1, max(0, round(fraction * (len(values) - 1))))
    return values[index]


median = statistics.median(times)
print(f"{percentile(times, 0.1):.4f} {median:.4f} {percentile(times, 0.9):.4f} "
      f"{size / median / (1024 * 1024):.1f}")
PY
)
  read -r p10 median p90 mbps <<<"$stats"
  MEDIANS_PAIRS="$MEDIANS_PAIRS $parallel:$median"
  echo "parallel=$parallel runs=$RUNS size=$((SIZE / 1024 / 1024))MB P10=${p10}s median=${median}s P90=${p90}s throughput=${mbps}MB/s"
done

python3 - "$MEDIANS_PAIRS" <<'PY'
import sys

medians = dict(
    (part.split(":", 1)[0], float(part.split(":", 1)[1]))
    for part in sys.argv[1].split()
    if ":" in part
)
if len(medians) >= 2:
    fastest = min(medians.values())
    slowest = max(medians.values())
    print(f"multi/single median ratio: {slowest / fastest:.2f}x")
PY

if [[ -n "${MACIDM_BENCH_REPORT:-}" ]]; then
  {
    echo "# MacIDM throughput benchmark $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "size_bytes=$SIZE runs=$RUNS"
    for pair in $MEDIANS_PAIRS; do
      echo "parallel=${pair%%:*} median=${pair##*:}"
    done
  } > "$MACIDM_BENCH_REPORT"
fi
echo "MacIDM throughput benchmark completed."
