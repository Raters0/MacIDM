#!/bin/bash

set -euo pipefail

install_directory="${MACIDM_DEBUG_INSTALL_DIRECTORY:-$HOME/Applications}"
expected_host="$install_directory/MacIDM.app/Contents/MacOS/macidm-host"
expected_origin="chrome-extension://obaipbnfoifafgcpekkfkapjifjgbjag/"

# Mirror the browser directory list from install-debug-native-host.sh so a
# single invocation can verify every installed manifest. We still tolerate
# extra directories supplied at install time through MACIDM_NMH_EXTRA_DIRS;
# the caller can re-export it before running this script to keep the two in
# lock-step.
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

any_checked=0
any_failed=0
for browser_dir in "${default_browser_dirs[@]}"; do
    manifest_path="$browser_dir/NativeMessagingHosts/com.macidm.host.json"
    if [[ ! -f "$manifest_path" ]]; then continue; fi
    any_checked=1
    /usr/bin/plutil -p "$manifest_path" >/dev/null
    actual_name="$(/usr/bin/plutil -extract name raw "$manifest_path")"
    actual_path="$(/usr/bin/plutil -extract path raw "$manifest_path")"
    actual_type="$(/usr/bin/plutil -extract type raw "$manifest_path")"
    actual_origin="$(/usr/bin/plutil -extract allowed_origins.0 raw "$manifest_path")"

    if [[ "$actual_name" != "com.macidm.host" ]]; then
        echo "清单 $manifest_path 名称不匹配：$actual_name" >&2
        any_failed=1
        continue
    fi
    if [[ "$actual_type" != "stdio" ]]; then
        echo "清单 $manifest_path 类型不匹配：$actual_type" >&2
        any_failed=1
        continue
    fi
    if [[ "$actual_path" != "$expected_host" ]]; then
        echo "清单 $manifest_path Host 路径已变化：$actual_path" >&2
        any_failed=1
        continue
    fi
    if [[ "$actual_origin" != "$expected_origin" ]]; then
        echo "清单 $manifest_path 默认扩展 ID 不匹配：$actual_origin" >&2
        any_failed=1
        continue
    fi
    if [[ ! -x "$actual_path" ]]; then
        echo "清单 $manifest_path Host 不可执行：$actual_path" >&2
        any_failed=1
        continue
    fi
    echo "✓ $manifest_path"
done

if [[ $any_checked -eq 0 ]]; then
    echo "未找到任何已安装的 Native Host 清单" >&2
    exit 1
fi
if [[ $any_failed -ne 0 ]]; then
    exit 1
fi

"$expected_host" --version
echo "MacIDM Native Host 清单检查通过。"
