#!/bin/bash
# Verifies the YouTube / yt-dlp toolchain end to end:
#   1. a yt-dlp binary resolves through the same lookup order the app uses
#      (MACIDM_YTDLP_PATH > managed copy > app bundle Resources > system);
#   2. the binary runs (--version);
#   3. YouTube metadata extraction works against a tiny, stable video;
#   4. a real small-format download completes and produces a non-empty file.
#
# A missing yt-dlp binary is a hard failure (that is exactly the
# YTDLP_NOT_FOUND regression this gate guards). Network problems downgrade
# steps 3/4 to a loud skip, since offline machines cannot exercise YouTube.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macidm-youtube.XXXXXX")"
TEST_URL="${MACIDM_YOUTUBE_TEST_URL:-https://www.youtube.com/watch?v=jNQXAC9IVRw}"

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

skip_network() {
  echo "SKIP: $1 (network unavailable; yt-dlp presence was still verified)" >&2
  exit 0
}

# Runtime candidates first; the build cache is a gate-only fallback, not proof
# that the installed App bundles this binary.
locate_ytdlp() {
  if [[ -n "${MACIDM_YTDLP_PATH:-}" ]] && [[ -x "$MACIDM_YTDLP_PATH" ]]; then
    echo "$MACIDM_YTDLP_PATH"
    return 0
  fi
  local managed="$HOME/Library/Application Support/MacIDM/yt-dlp"
  if [[ -x "$managed" ]]; then
    echo "$managed"
    return 0
  fi
  local bundled="$HOME/Applications/MacIDM.app/Contents/Resources/yt-dlp"
  if [[ -x "$bundled" ]]; then
    echo "$bundled"
    return 0
  fi
  local vendor="${MACIDM_YTDLP_CACHE:-$HOME/Library/Caches/MacidM/yt-dlp}/yt-dlp"
  if [[ -x "$vendor" ]]; then
    echo "$vendor"
    return 0
  fi
  local candidate
  for candidate in /opt/homebrew/bin/yt-dlp /usr/local/bin/yt-dlp /usr/bin/yt-dlp "$HOME/.local/bin/yt-dlp"; do
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

YTDLP_BIN="$(locate_ytdlp)" || fail "no yt-dlp binary found; run scripts/fetch-ytdlp.sh or brew install yt-dlp"
echo "yt-dlp binary: $YTDLP_BIN"

VERSION="$("$YTDLP_BIN" --version 2>/dev/null)" || fail "yt-dlp binary is not executable"
echo "yt-dlp version: $VERSION"

# Network probe: YouTube must be reachable before the online steps run.
if ! curl --silent --fail --max-time 15 --output /dev/null "https://www.youtube.com"; then
  skip_network "youtube.com is not reachable"
fi

echo "--- extraction check ---"
# YouTube bot-checks anonymous CLI requests from many IPs. The app solves
# this with browser cookies, so retry with Chrome cookies before treating an
# extraction failure as a real regression.
COOKIE_ARGS=()
EXTRACTED_ID=""
if ! EXTRACTED_ID="$("$YTDLP_BIN" --simulate --no-warnings --print "%(id)s" "$TEST_URL" 2>"$TEST_DIR/extract.log")"; then
  if grep -qiE "sign in to confirm|not a bot" "$TEST_DIR/extract.log"; then
    if [[ "${MACIDM_YOUTUBE_ALLOW_BROWSER_COOKIES:-0}" != "1" ]]; then
      skip_network "YouTube requires login; browser-cookie fallback was not authorized (set MACIDM_YOUTUBE_ALLOW_BROWSER_COOKIES=1 to opt in)"
    fi
    echo "anonymous request hit YouTube's bot check; retrying with Chrome cookies"
    COOKIE_ARGS=(--cookies-from-browser chrome)
    if ! EXTRACTED_ID="$("$YTDLP_BIN" --simulate --no-warnings --print "%(id)s" ${COOKIE_ARGS[@]+"${COOKIE_ARGS[@]}"} "$TEST_URL" 2>"$TEST_DIR/extract.log")"; then
      if grep -qiE "sign in to confirm|not a bot" "$TEST_DIR/extract.log"; then
        skip_network "YouTube bot check persists even with Chrome cookies (login-state issue, not a toolchain regression)"
      fi
      cat "$TEST_DIR/extract.log" >&2
      fail "yt-dlp could not extract YouTube metadata (stale yt-dlp?)"
    fi
  else
    cat "$TEST_DIR/extract.log" >&2
    fail "yt-dlp could not extract YouTube metadata (stale yt-dlp or bot check)"
  fi
fi
[[ -n "$EXTRACTED_ID" ]] || fail "yt-dlp returned an empty video id"
echo "extracted video id: $EXTRACTED_ID"

echo "--- small-format download check ---"
"$YTDLP_BIN" \
  --no-warnings \
  --no-playlist \
  ${COOKIE_ARGS[@]+"${COOKIE_ARGS[@]}"} \
  -f "b[height<=360]/b" \
  --merge-output-format mp4 \
  --retries 3 \
  -o "$TEST_DIR/video.%(ext)s" \
  "$TEST_URL" \
  || fail "yt-dlp failed to download the smallest format"

DOWNLOADED="$(find "$TEST_DIR" -maxdepth 1 -name 'video.*' -type f | head -1)"
[[ -n "$DOWNLOADED" ]] || fail "no output file was produced"
SIZE="$(stat -f%z "$DOWNLOADED")"
[[ "$SIZE" -gt 10240 ]] || fail "downloaded file is suspiciously small ($SIZE bytes)"
echo "downloaded $(basename "$DOWNLOADED"): $SIZE bytes"

echo "youtube-ytdlp-integration: PASS"
