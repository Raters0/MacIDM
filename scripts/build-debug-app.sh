#!/bin/bash

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
# Debug is the daily-driver configuration. Release exists for published
# bundles: optimized, no DWARF, so shipped binaries carry neither debug
# info nor absolute source paths. Everything else in this script is
# configuration-independent.
app_configuration="${MACIDM_APP_CONFIGURATION:-debug}"
case "$app_configuration" in
  debug|release) ;;
  *) echo "[build-debug-app] unsupported MACIDM_APP_CONFIGURATION: $app_configuration" >&2; exit 1 ;;
esac
build_directory="$repository_root/.build/$app_configuration"
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
swift build --disable-sandbox --configuration "$app_configuration" --product MacIDMDesktop >&2
swift build --disable-sandbox --configuration "$app_configuration" --product macidm-host >&2

# Icons are generated artifacts (deterministic); regenerate every build.
bash "$repository_root/scripts/generate-icons.sh" >/dev/null

mkdir -p "$contents_directory/MacOS" "$contents_directory/Resources"
cp "$build_directory/MacIDMDesktop" "$contents_directory/MacOS/MacIDM"
cp "$build_directory/macidm-host" "$contents_directory/MacOS/macidm-host"

# SwiftPM links Sparkle via @rpath but only emits /usr/lib/swift and
# @loader_path runpaths — enough when running from .build/debug where the
# framework sits next to the binary, not inside the bundle where it lives
# in Contents/Frameworks. Add the standard app rpath before re-signing.
if ! otool -l "$contents_directory/MacOS/MacIDM" | grep -q '@executable_path/../Frameworks'; then
  /usr/bin/install_name_tool -add_rpath "@executable_path/../Frameworks" "$contents_directory/MacOS/MacIDM"
fi
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

# Sparkle 2 update engine (technical-spec §6.1): embed the SwiftPM-produced
# dynamic framework; its nested updater XPC services ride along inside the
# framework and are covered by the deep ad-hoc signature below.
frameworks_directory="$contents_directory/Frameworks"
rm -rf "$frameworks_directory/Sparkle.framework"
mkdir -p "$frameworks_directory"
cp -R "$build_directory/Sparkle.framework" "$frameworks_directory/Sparkle.framework"

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
  /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 1.0.2" "$info_plist"
  # Sparkle compares its appcast's sparkle:version against the host
  # bundle's CFBundleVersion, so both must carry the same marketing
  # version (the appcast is generated from the same value).
  /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string 1.0.2" "$info_plist"
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
  # Sparkle update feed. The EdDSA public key is not a secret and lives in
  # the repository; the matching private key exists only in the release
  # engineer's keychain (scripts/package-update-release.sh signs with it).
  sparkle_public_key="$(tr -d '[:space:]' < "$repository_root/scripts/sparkle-eddsa-public-key.txt")"
  if [ -z "$sparkle_public_key" ]; then
    echo "[build-debug-app] missing Sparkle public key: scripts/sparkle-eddsa-public-key.txt" >&2
    exit 1
  fi
  /usr/libexec/PlistBuddy -c "Add :SUFeedURL string https://github.com/Raters0/MacIDM/releases/latest/download/appcast.xml" "$info_plist"
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $sparkle_public_key" "$info_plist"
  /usr/libexec/PlistBuddy -c "Add :SUScheduledCheckInterval integer 86400" "$info_plist"
} >&2

/usr/bin/codesign --force --deep --sign - "$application_directory" >&2

echo "$application_directory"
