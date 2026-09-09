#!/bin/bash

set -euo pipefail

install_directory="${MACIDM_DEBUG_INSTALL_DIRECTORY:-$HOME/Applications}"
expected_host="$install_directory/MacIDM.app/Contents/MacOS/macidm-host"
expected_name="com.macidm.host"

# Mirror the browser directory list from install-debug-native-host.sh so we
# sweep every location where the installer writes a manifest.
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

removed_count=0
skipped_count=0
for browser_dir in "${default_browser_dirs[@]}"; do
    manifest_path="$browser_dir/NativeMessagingHosts/com.macidm.host.json"
    if [[ ! -e "$manifest_path" ]]; then continue; fi

    actual_name="$(/usr/bin/plutil -extract name raw "$manifest_path" 2>/dev/null || true)"
    actual_path="$(/usr/bin/plutil -extract path raw "$manifest_path" 2>/dev/null || true)"

    # Safety net: only delete manifests this script can identify as belonging
    # to this local MacIDM installation. Anything else (e.g. a real Chrome Web Store manifest
    # with the same filename) is left alone so the user does not lose their
    # production install.
    if [[ "$actual_name" != "$expected_name" || "$actual_path" != "$expected_host" ]]; then
        echo "跳过非当前 MacIDM 安装所属的清单：$manifest_path" >&2
        skipped_count=$((skipped_count + 1))
        continue
    fi

    rm "$manifest_path"
    removed_count=$((removed_count + 1))
done

if [[ $removed_count -eq 0 && $skipped_count -eq 0 ]]; then
    echo "MacIDM Native Host 清单不存在，无需移除。"
elif [[ $removed_count -eq 0 ]]; then
    echo "未删除任何清单（全部被识别为非当前 MacIDM 安装所属）。"
else
    echo "已移除 $removed_count 处 MacIDM Native Host 清单；该操作不会删除 App、扩展或下载任务。"
fi
