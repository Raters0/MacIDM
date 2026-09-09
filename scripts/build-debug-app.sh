#!/bin/bash

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
build_directory="$repository_root/.build/debug"
application_directory="$build_directory/MacIDM.app"
contents_directory="$application_directory/Contents"

cd "$repository_root"
# Per-user cache directories: a fixed /tmp path is shared across accounts and
# can be pre-created by another local user (module-cache poisoning/conflicts).
user_cache_root="${TMPDIR:-/tmp}/macidm-build-cache-$(id -u)"
export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-$user_cache_root/swift}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$user_cache_root/clang}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$user_cache_root/swiftpm}"
mkdir -p "$SWIFT_MODULECACHE_PATH" "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"
swift build --disable-sandbox --product MacIDMDesktop >&2
swift build --disable-sandbox --product macidm-host >&2

# Icons are generated artifacts (deterministic); regenerate every build.
bash "$repository_root/scripts/generate-icons.sh" >/dev/null

mkdir -p "$contents_directory/MacOS" "$contents_directory/Resources"
cp "$build_directory/MacIDMDesktop" "$contents_directory/MacOS/MacIDM"
cp "$build_directory/macidm-host" "$contents_directory/MacOS/macidm-host"
cp "$repository_root/Resources/AppIcon.icns" "$contents_directory/Resources/AppIcon.icns"
cp "$repository_root/Resources/MenuBarIcon.png" "$contents_directory/Resources/MenuBarIcon.png"
cp "$repository_root/Resources/MenuBarIcon@2x.png" "$contents_directory/Resources/MenuBarIcon@2x.png"

# Localization catalogs: zh-Hans is the development region (keys are the
# Chinese literals), en carries the translations. Adding a language means
# adding a .lproj here and to CFBundleLocalizations below. Remove stale
# copies first: cp -R nests the source inside an existing destination.
rm -rf "$contents_directory/Resources/zh-Hans.lproj" "$contents_directory/Resources/en.lproj"
cp -R "$repository_root/Resources/Localization/zh-Hans.lproj" "$contents_directory/Resources/zh-Hans.lproj"
cp -R "$repository_root/Resources/Localization/en.lproj" "$contents_directory/Resources/en.lproj"

# Bundle the yt-dlp standalone binary so the app does not depend on a
# system-wide installation. Best-effort: offline builds skip bundling and
# the app falls back to external yt-dlp lookups at runtime.
if ytdlp_path="$(bash "$repository_root/scripts/fetch-ytdlp.sh")" && [ -f "$ytdlp_path" ]; then
  cp "$ytdlp_path" "$contents_directory/Resources/yt-dlp"
  chmod 755 "$contents_directory/Resources/yt-dlp"
  echo "[build-debug-app] bundled yt-dlp into Resources" >&2
else
  echo "[build-debug-app] yt-dlp unavailable; bundling skipped" >&2
fi

info_plist="$contents_directory/Info.plist"
{
  /usr/libexec/PlistBuddy -c "Clear dict" "$info_plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :CFBundleDevelopmentRegion string zh_CN" "$info_plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleLocalizations array" "$info_plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleLocalizations:0 string zh-Hans" "$info_plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleLocalizations:1 string en" "$info_plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string MacIDM" "$info_plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string MacIDM" "$info_plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.macidm.app" "$info_plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$info_plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleInfoDictionaryVersion string 6.0" "$info_plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleName string MacIDM" "$info_plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$info_plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 0.3.0" "$info_plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string 1" "$info_plist"
  /usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 13.0" "$info_plist"
  /usr/libexec/PlistBuddy -c "Add :NSHighResolutionCapable bool true" "$info_plist"
  /usr/libexec/PlistBuddy -c "Add :NSPrincipalClass string NSApplication" "$info_plist"
  # Inject build timestamp so the app can display the build date in Settings,
  # letting users verify they are running the latest build.
  build_date="$(date '+%Y-%m-%d %H:%M:%S')"
  /usr/libexec/PlistBuddy -c "Add :MacIDMBuildDate string $build_date" "$info_plist"
  build_hash="$(git -C "$repository_root" rev-parse --short HEAD 2>/dev/null || echo "unknown")"
  /usr/libexec/PlistBuddy -c "Add :MacIDMBuildCommit string $build_hash" "$info_plist"
  /usr/libexec/PlistBuddy -c "Add :MacIDMLocalDevelopmentBuild bool true" "$info_plist"
} >&2

/usr/bin/codesign --force --deep --sign - "$application_directory" >&2

echo "$application_directory"
