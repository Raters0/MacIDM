#!/bin/bash
# 4A-5 轻量固定样本门禁。
#
# 用 CLI 前台模式下载一组冻结的合法公开测试样本（直链 + HLS + DASH），
# 验证 HTTP 分段、HLS 解析/remux、DASH 配对/merge 三条链路在真实网络
# 上的端到端可用性。本地素材回归由 hls-download-integration.sh /
# app-media-pipeline-integration.sh 覆盖，
# 本脚本只负责公开样本部分。
#
# 样本失效处理规则：样本失效时按"同协议、同特征、长期稳定的合法公开
# 测试流"标准替换，并在本文件顶部的替换记录中登记，不允许静默移除。
#
# 替换记录：
#   2026-08-11 首次冻结 6 个样本（3 直链 + 2 HLS + 1 DASH）。
#   2026-08-11 dashif-bbb-30fps（dash.akamaized.net）在本机环境持续 TLS
#     握手失败，按同协议/同特征规则替换为 Unified Streaming 公开演示
#     Tears of Steel MPD（长期稳定的官方特性演示源）。
#   2026-08-11 unified-tos-dash（demo.unified-streaming.com）在本机直连
#     带宽仅约 5KB/s，900s 看门狗必超时；候选 Angel One（Shaka 演示
#     资产）是 on-demand profile（SegmentBase），超出引擎支持面，
#     最终按同协议/同特征规则替换为 xgplayer 官方演示 DASH（字节
#     火山 CDN、长期稳定，90s 混流 SegmentList 约 66MB，适配门禁
#     时长预算；该样本同时暴露并修复了 SegmentList 省略 sourceURL
#     的解析缺口）。
#   2026-08-11 mux-bbb-hls（test-streams.mux.dev，488MB）在本机直连吞吐
#     多次低于 900s 看门狗所需带宽；按同协议/同特征规则替换为 Apple
#     经典 bipbop_4x3 多档 HLS（master + TS 分片特征不变，最高档约
#     145MB，与另一 Apple 样本同源 CDN 但体量小一个量级）。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
MACIDM_BIN="$ROOT_DIR/.build/debug/macidm"
TIMEOUT_SECONDS="${MACIDM_SAMPLE_GATE_TIMEOUT:-900}"

# 本机代理不稳定时可设 MACIDM_SAMPLE_GATE_NOPROXY=1 直连样本源：
# ① 剥离 curl 探测的环境代理变量；② 给引擎传 MACIDM_FORCE_DIRECT=1，
# 让 URLSession 绕过操作系统级代理设置（仅剥环境变量对引擎无效）。
# 始终以 env 开头保持数组非空：bash 3.2 + set -u 对空数组展开会报 unbound。
PROXY_ENV=(env)
if [[ "${MACIDM_SAMPLE_GATE_NOPROXY:-0}" == "1" ]]; then
  PROXY_ENV=(env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY MACIDM_FORCE_DIRECT=1)
  echo "==> 已按 MACIDM_SAMPLE_GATE_NOPROXY=1 绕过环境代理与系统代理直连样本源"
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macidm-sample-gate.XXXXXX")"
STATE_DIR="$WORK_DIR/state"
OUT_DIR="$WORK_DIR/out"
mkdir -p "$STATE_DIR" "$OUT_DIR"
trap 'rm -rf "$WORK_DIR"' EXIT

PASS=0
FAIL=0
SKIP=0
FAILED_NAMES=()
SKIPPED_NAMES=()

# 冻结样本清单：名称|类型(http|hls|dash)|URL|最小产物字节数
SAMPLES=(
  "w3c-sintel-trailer|http|https://media.w3.org/2010/05/sintel/trailer.mp4|500000"
  "test-videos-bbb-360|http|https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/360/Big_Buck_Bunny_360_10s_1MB.mp4|900000"
  "test-videos-sintel-360|http|https://test-videos.co.uk/vids/sintel/mp4/h264/360/Sintel_360_10s_1MB.mp4|900000"
  "apple-bipbop-4x3|hls|https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_4x3/bipbop_4x3_variant.m3u8|100000000"
  "apple-bipbop-adv-fmp4|hls|https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8|5000000"
  "xgplayer-demo-dash|dash|https://sf1-cdn-tos.huoshanstatic.com/obj/media-fe/xgplayer_doc_video/dash/xgplayer-demo-dash.mpd|10000000"
)

echo "==> 构建 macidm CLI"
(cd "$ROOT_DIR" && swift build --product macidm)

run_with_timeout() {
  local seconds="$1"
  shift
  "$@" &
  local job_pid=$!
  (
    sleep "$seconds"
    kill "$job_pid" 2>/dev/null
  ) &
  local watcher_pid=$!
  local code=0
  wait "$job_pid" || code=$?
  kill "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true
  return "$code"
}

probe_url() {
  "${PROXY_ENV[@]}" curl --silent --fail --location --max-time 30 \
    --range 0-1023 --output /dev/null "$1"
}

has_ffmpeg() {
  [[ -n "${MACIDM_FFMPEG_PATH:-}" ]] || command -v ffmpeg >/dev/null 2>&1
}

for entry in "${SAMPLES[@]}"; do
  IFS='|' read -r name kind url min_bytes <<<"$entry"
  output="$OUT_DIR/$name"
  echo ""
  echo "==> 样本 ${name} (${kind})"

  if ! probe_url "$url"; then
    echo "    SKIP：探测失败（网络不可达或样本失效）。若多次复现，按脚本头部规则替换样本并登记。" >&2
    SKIP=$((SKIP + 1))
    SKIPPED_NAMES+=("$name")
    continue
  fi

  if [[ "$kind" != "http" ]] && ! has_ffmpeg; then
    echo "    SKIP：$kind 样本需要 FFmpeg 工具链（配置 MACIDM_FFMPEG_PATH 或安装 ffmpeg）。" >&2
    SKIP=$((SKIP + 1))
    SKIPPED_NAMES+=("$name")
    continue
  fi

  if run_with_timeout "$TIMEOUT_SECONDS" \
    "${PROXY_ENV[@]}" "$MACIDM_BIN" --state-dir "$STATE_DIR" add "$url" \
    --output "$output" --parallel 8 --foreground
  then
    :
  else
    echo "    FAIL：CLI 下载退出码非零。" >&2
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$name")
    continue
  fi

  if [[ ! -f "$output" ]]; then
    echo "    FAIL：产物文件不存在：${output}" >&2
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$name")
    continue
  fi

  size=$(stat -f%z "$output")
  if ((size < min_bytes)); then
    echo "    FAIL：产物 $size 字节，低于门禁下限 $min_bytes 字节。" >&2
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$name")
    continue
  fi

  echo "    PASS：产物 ${size} 字节（下限 ${min_bytes}）。"
  PASS=$((PASS + 1))
done

echo ""
echo "==> 样本门禁结果：$PASS 通过 / $FAIL 失败 / $SKIP 跳过（共 ${#SAMPLES[@]}）"
if ((FAIL > 0)); then
  echo "失败样本：${FAILED_NAMES[*]}" >&2
  exit 1
fi
if ((PASS == 0)); then
  echo "所有样本都被跳过，门禁未获得任何验证；请在可用网络环境中重跑。" >&2
  exit 3
fi
if ((SKIP > 0)); then
  echo "注意：以下样本被跳过，门禁结论不完整：${SKIPPED_NAMES[*]}" >&2
fi
echo "MacIDM sample gate passed."
