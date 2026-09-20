#!/bin/bash
# Restore the pinned hls.js light build shipped with the extension.
# The committed integrity file or HLS_JS_SHA256 must authenticate the download.
set -euo pipefail

version="${HLS_JS_VERSION:-1.5.13}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lib_dir="$repo_root/BrowserExtension/chrome/lib"
js_path="$lib_dir/hls.light.min.js"
integrity_path="$lib_dir/hls.light.min.js.integrity"
url="https://cdn.jsdelivr.net/npm/hls.js@${version}/dist/hls.light.min.js"

mkdir -p "$lib_dir"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

curl -fsSL --retry 3 --max-time 120 -o "$staging/hls.light.min.js" "$url"
# Sanity: the light build must expose the Hls global and be non-trivial in size.
grep -q "Hls" "$staging/hls.light.min.js" || { echo '[fetch-hls] downloaded file does not expose Hls' >&2; exit 1; }
bytes="$(wc -c < "$staging/hls.light.min.js" | tr -d ' ')"
[[ "$bytes" -gt 50000 ]] || { echo "[fetch-hls] suspiciously small payload ($bytes bytes)" >&2; exit 1; }
digest="$(shasum -a 256 "$staging/hls.light.min.js" | awk '{print $1}')"

expected="${HLS_JS_SHA256:-}"
if [[ -z "$expected" && -f "$integrity_path" ]]; then
  expected="$(sed -n '1p' "$integrity_path")"
fi
if [[ -n "$expected" ]]; then
  [[ "$digest" == "$expected" ]] || { echo '[fetch-hls] sha256 mismatch' >&2; exit 1; }
else
  echo '[fetch-hls] expected SHA-256 is required before installing hls.js' >&2
  exit 1
fi

mv -f "$staging/hls.light.min.js" "$js_path"
printf '%s\n%s\n' "$digest" "$version" > "$integrity_path"
echo "$js_path"
