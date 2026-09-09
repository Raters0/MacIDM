#!/bin/bash
# Resolve and verify an official release before executing or publishing it.
set -euo pipefail
cache_directory="${MACIDM_YTDLP_CACHE:-$HOME/Library/Caches/MacidM/yt-dlp}"
mkdir -p "$cache_directory"
cache_directory="$(cd "$cache_directory" && pwd)"
binary_path="$cache_directory/yt-dlp"
metadata_path="$cache_directory/yt-dlp.integrity"
force=false
if [[ "${1:-}" == --force ]]; then force=true; fi

verify() {
  local binary="$1" metadata="$2" digest version actual
  [[ -f "$binary" && -f "$metadata" ]] || return 1
  digest="$(sed -n '1p' "$metadata")"
  version="$(sed -n '2p' "$metadata")"
  [[ "$digest" =~ ^[a-f0-9]{64}$ && "$version" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}$ ]] || return 1
  actual="$(shasum -a 256 "$binary" | awk '{print $1}')"
  [[ "$actual" == "$digest" ]] || return 1
  [[ -x "$binary" && "$("$binary" --version)" == "$version" ]]
}
if [[ "$force" == false ]] && verify "$binary_path" "$metadata_path"; then
  echo "$binary_path"
  exit 0
fi

lock_dir="$cache_directory/fetch.lock"
mkdir "$lock_dir" 2>/dev/null || { echo '[fetch-ytdlp] another fetch is running' >&2; exit 1; }
staging="$(mktemp -d "$cache_directory/.fetch.XXXXXX")"
replacing=false
cleanup() {
  local result=$?
  if [[ "$replacing" == true ]]; then
    rm -f "$binary_path" "$metadata_path"
    if [[ -f "$staging/old-binary" ]]; then mv "$staging/old-binary" "$binary_path"; fi
    if [[ -f "$staging/old-metadata" ]]; then mv "$staging/old-metadata" "$metadata_path"; fi
  fi
  rm -rf "$staging"
  rmdir "$lock_dir"
  exit "$result"
}
trap cleanup EXIT
curl -fsSL --max-time 20 https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest > "$staging/release.json"
python3 - "$staging/release.json" > "$staging/release-info" <<'PY'
import json, re, sys
release = json.load(open(sys.argv[1]))
tag = release.get('tag_name', '')
if not re.fullmatch(r'\d{4}\.\d{2}\.\d{2}', tag):
    sys.exit('Missing or invalid official release tag')
asset = next((a for a in release.get('assets', []) if a.get('name') == 'yt-dlp_macos'), None)
if asset is None:
    sys.exit('Official macOS asset is missing')
digest = asset.get('digest') or ''
if digest and not re.fullmatch(r'sha256:[a-fA-F0-9]{64}', digest):
    sys.exit('Invalid release digest')
print(tag)
print(digest.removeprefix('sha256:').lower())
PY
version="$(sed -n '1p' "$staging/release-info")"
digest="$(sed -n '2p' "$staging/release-info")"
release_url="https://github.com/yt-dlp/yt-dlp/releases/download/$version"
if [[ -z "$digest" ]]; then
  curl -fsSL --max-time 30 "$release_url/SHA2-256SUMS" > "$staging/sums"
  digest="$(awk '$2 == "yt-dlp_macos" || $2 == "*yt-dlp_macos" {print tolower($1)}' "$staging/sums")"
fi
[[ "$digest" =~ ^[a-f0-9]{64}$ ]] || { echo '[fetch-ytdlp] missing or invalid checksum' >&2; exit 1; }
curl -fL --retry 3 --max-time 300 -o "$staging/binary" "$release_url/yt-dlp_macos"
printf '%s\n%s\n' "$digest" "$version" > "$staging/metadata"
# verify() hashes before executing. chmod alone never executes the download.
chmod 755 "$staging/binary"
verify "$staging/binary" "$staging/metadata" || { echo '[fetch-ytdlp] checksum or version mismatch' >&2; exit 1; }
# Preserve the old pair until both renames succeed. Never execute an old cache
# lacking matching integrity metadata to decide whether it is usable.
if [[ -f "$binary_path" ]]; then cp -p "$binary_path" "$staging/old-binary"; fi
if [[ -f "$metadata_path" ]]; then cp -p "$metadata_path" "$staging/old-metadata"; fi
replacing=true
mv -f "$staging/binary" "$binary_path"
mv -f "$staging/metadata" "$metadata_path"
replacing=false
echo "$binary_path"
