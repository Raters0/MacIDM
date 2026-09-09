#!/bin/bash

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
install_directory="${MACIDM_DEBUG_INSTALL_DIRECTORY:-$HOME/Applications}"
destination="$install_directory/MacIDM.app"
legacy_destination="$install_directory/MacIDM Debug.app"
launch_services_register="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [[ "$install_directory" != /* || "$install_directory" == "/" ]]; then
  echo "[install-debug-app] install directory must be a non-root absolute path: $install_directory" >&2
  exit 1
fi

# Serialize the whole check-and-replace critical section: two concurrent
# installs would otherwise race between the running-process check and the
# bundle replacement (macOS ships no flock(1); mkdir is the atomic lock).
lock_parent="$HOME/Library/Caches/MacidM"
mkdir -p "$lock_parent"
lock_dir="$lock_parent/install.lock"
if ! mkdir "$lock_dir" 2>/dev/null; then
  echo "[install-debug-app] another install is already running (lock: $lock_dir)." >&2
  exit 1
fi
staging=""
backup=""
replacing=false
committed=false
cleanup() {
  local result=$?
  if [[ "$committed" == false && ( "$replacing" == true || ( -n "$backup" && -d "$backup" ) ) ]]; then
    rm -rf "$destination"
    if [[ -d "$backup" ]]; then mv "$backup" "$destination"; fi
  fi
  if [[ -n "$staging" ]]; then rm -rf "$staging"; fi
  rmdir "$lock_dir" 2>/dev/null || true
  exit "$result"
}
trap cleanup EXIT

ensure_app_is_not_running() {
  if pgrep -x MacIDM >/dev/null 2>&1; then
    echo "[install-debug-app] MacIDM is running; quit it after active downloads finish, then retry." >&2
    exit 1
  fi
}

ensure_app_is_not_running

source_app="$(bash "$repository_root/scripts/build-debug-app.sh")"
expected_source_app="$repository_root/.build/debug/MacIDM.app"
if [[ "$source_app" != "$expected_source_app" ]]; then
  echo "[install-debug-app] unexpected build output: $source_app" >&2
  exit 1
fi

read_plist_value() {
  local key="$1"
  local bundle="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$bundle/Contents/Info.plist"
}

source_build_date="$(read_plist_value MacIDMBuildDate "$source_app")"
source_bundle_id="$(read_plist_value CFBundleIdentifier "$source_app")"
source_executable="$(read_plist_value CFBundleExecutable "$source_app")"
if [[ "$source_bundle_id" != "com.macidm.app" || "$source_executable" != "MacIDM" ]]; then
  echo "[install-debug-app] build metadata is not the stable MacIDM identity" >&2
  exit 1
fi

# A browser can start the legacy App through an old Native Host manifest while
# the build is running. Recheck immediately before replacing either bundle.
ensure_app_is_not_running

mkdir -p "$install_directory"
# Copy and validate on the destination volume before moving the installed app.
# This private directory is never launched or registered with Launch Services.
staging="$(mktemp -d "$install_directory/.macidm-install.XXXXXX")"
staged_app="$staging/bundle"
backup="$staging/previous"
ditto "$source_app" "$staged_app"
if [[ "$(read_plist_value MacIDMBuildDate "$staged_app")" != "$source_build_date" \
    || "$(read_plist_value CFBundleIdentifier "$staged_app")" != "$source_bundle_id" \
    || "$(read_plist_value CFBundleExecutable "$staged_app")" != "$source_executable" \
    || "$(read_plist_value CFBundleDisplayName "$staged_app")" != "MacIDM" \
    || ! -x "$staged_app/Contents/MacOS/MacIDM" ]]; then
  echo "[install-debug-app] staged bundle does not match the freshly built bundle" >&2
  exit 1
fi
ensure_app_is_not_running
if [[ -e "$destination" ]]; then mv "$destination" "$backup"; fi
replacing=true
mv "$staged_app" "$destination"
committed=true
replacing=false
rm -rf "$backup"

# The installed bundle is the only user-facing app. Remove the
# reproducible packaging bundle after a successful copy so Launch Services,
# Spotlight, and testers cannot accidentally open a stale second instance.
rm -rf "$expected_source_app"

# The App used to be installed under this development-only display name.
# Remove that fixed legacy path after the new copy succeeds so Launch Services
# cannot expose two bundles with the same identifier and task state. The
# default ~/Applications copy is cleaned even when installing into a custom
# directory, matching the AGENTS.md legacy name.
legacy_default_destination="$HOME/Applications/MacIDM Debug.app"
for legacy_bundle in "$legacy_destination" "$legacy_default_destination"; do
  if [[ -d "$legacy_bundle" ]]; then
    # Tell Launch Services about the removal before deleting the old bundle.
    # Removing only the directory leaves the former display name and icon in
    # macOS app/menu-bar registries until the system eventually prunes them.
    "$launch_services_register" -u "$legacy_bundle" >/dev/null 2>&1 || true
    rm -rf "$legacy_bundle"
  fi
done

# Refresh the single surviving identity after the in-place bundle update.
"$launch_services_register" -f "$destination" >/dev/null 2>&1 || true

echo "$destination"
