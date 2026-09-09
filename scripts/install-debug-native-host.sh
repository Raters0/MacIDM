#!/bin/bash

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
extension_id="obaipbnfoifafgcpekkfkapjifjgbjag"
install_directory="${MACIDM_DEBUG_INSTALL_DIRECTORY:-$HOME/Applications}"
installed_app="$install_directory/MacIDM.app"

# The install script intentionally does NOT rebuild the host itself. Rebuilding
# triggers a full SwiftPM build plus a `ditto` that, in some shells, runs
# under an external tooling wrapper that aborts the parent script via set -u
# when its internal arrays are not pre-populated. Callers
# that want a fresh host run `bash scripts/install-debug-app.sh` first; here
# we only need to verify the existing binary is in place so the manifest
# points at a real executable.
host_path="$installed_app/Contents/MacOS/macidm-host"

if [[ ! -x "$host_path" ]]; then
    echo "Debug Host 不存在或不可执行：$host_path" >&2
    echo "请先运行：bash scripts/install-debug-app.sh" >&2
    exit 1
fi

# Build the list of allowed extension IDs. The default is the production
# Chrome Web Store ID. Users running local dev copies in other browsers (for
# example, ego lite) can append their dynamically-generated ID via the
# MACIDM_NMH_ALLOWED_ORIGINS environment variable, using half-width commas
# as the separator, e.g.:
#   export MACIDM_NMH_ALLOWED_ORIGINS="abcdefghijklmnopqrstuvwxyzabcdef,obaipbnfoifafgcpekkfkapjifjgbjag"
extra_origins="${MACIDM_NMH_ALLOWED_ORIGINS:-}"
allowed_origins=("$extension_id")
if [[ -n "$extra_origins" ]]; then
    IFS=',' read -r -a extra_list <<<"$extra_origins"
    for candidate in "${extra_list[@]}"; do
        trimmed="$(echo "$candidate" | tr -d '[:space:]')"
        if [[ -z "$trimmed" ]]; then continue; fi
        # Basic sanity: Chrome extension IDs are 32 lowercase letters. Anything
        # else almost certainly indicates a typo in the environment variable.
        if [[ ! "$trimmed" =~ ^[a-p]{32}$ ]]; then
            echo "忽略非法的扩展 ID：$trimmed（期望 32 个 a-p 字符）" >&2
            continue
        fi
        # De-duplicate so the manifest stays clean.
        if [[ " ${allowed_origins[*]} " == *" $trimmed "* ]]; then continue; fi
        allowed_origins+=("$trimmed")
    done
fi

# Build the list of NativeMessagingHosts directories to register the manifest
# into. The list covers the browsers MacIDM developers and testers commonly
# run on macOS. Unknown browsers can be added through
# MACIDM_NMH_EXTRA_DIRS (half-width comma-separated absolute paths). Each
# entry below points at the per-user Chromium-style NativeMessagingHosts
# directory; create the directory on demand and skip if the parent does not
# exist (so we do not litter the filesystem for browsers the user has not
# installed).
default_browser_dirs=(
    "$HOME/Library/Application Support/Google/Chrome"
    "$HOME/Library/Application Support/Citro Labs/ego lite/Default"
    "$HOME/Library/Application Support/Chromium"
    "$HOME/Library/Application Support/BraveSoftware/Brave-Browser"
    "$HOME/Library/Application Support/Microsoft Edge"
    "$HOME/Library/Application Support/com.operasoftware.Opera"
    "$HOME/Library/Application Support/Vivaldi"
    "$HOME/Library/Application Support/Arc"
)
extra_dirs="${MACIDM_NMH_EXTRA_DIRS:-}"
if [[ -n "$extra_dirs" ]]; then
    IFS=',' read -r -a extra_dir_list <<<"$extra_dirs"
    default_browser_dirs+=("${extra_dir_list[@]}")
fi

# Serialize allowed_origins into a JSON array literal we can hand to plutil.
allowed_origins_json="["
for i in "${!allowed_origins[@]}"; do
    if [[ $i -gt 0 ]]; then allowed_origins_json+=","; fi
    allowed_origins_json+="\"chrome-extension://${allowed_origins[$i]}/\""
done
allowed_origins_json+="]"

# Track which directories accepted the manifest so the success message stays
# truthful.
installed_dirs=()
for browser_dir in "${default_browser_dirs[@]}"; do
    nmh_dir="$browser_dir/NativeMessagingHosts"
    if [[ ! -d "$browser_dir" ]]; then continue; fi
    mkdir -p "$nmh_dir"
    manifest_path="$nmh_dir/com.macidm.host.json"
    temporary_manifest="$(mktemp "$nmh_dir/.com.macidm.host.XXXXXX")"
    trap 'rm -f "$temporary_manifest"' EXIT

    /usr/bin/plutil -create xml1 "$temporary_manifest"
    /usr/bin/plutil -insert name -string "com.macidm.host" "$temporary_manifest"
    /usr/bin/plutil -insert description -string "MacIDM Native Messaging Host" "$temporary_manifest"
    /usr/bin/plutil -insert path -string "$host_path" "$temporary_manifest"
    /usr/bin/plutil -insert type -string "stdio" "$temporary_manifest"
    /usr/bin/plutil -insert allowed_origins -json "$allowed_origins_json" "$temporary_manifest"
    /usr/bin/plutil -convert json "$temporary_manifest"
    chmod 600 "$temporary_manifest"
    mv "$temporary_manifest" "$manifest_path"
    trap - EXIT
    installed_dirs+=("$manifest_path")
done

if [[ ${#installed_dirs[@]} -eq 0 ]]; then
    echo "未找到任何已安装的浏览器目录；可通过 MACIDM_NMH_EXTRA_DIRS 追加。" >&2
    echo "Host 路径：$host_path" >&2
    exit 1
fi

echo "已安装 MacIDM Native Host 清单："
for path in "${installed_dirs[@]}"; do
    echo "  $path"
done
echo "允许的扩展 ID："
for id in "${allowed_origins[@]}"; do
    echo "  $id"
done
