#!/bin/bash

# Package a MacIDM release for Sparkle auto-update (technical-spec §6.1).
# Builds the app bundle, zips it, signs the archive with the Sparkle EdDSA
# private key (login Keychain), and generates the appcast.xml that points
# at the pinned GitHub Release download URL.
#
# Publishing stays manual: run the printed `gh release create ...` command
# (or upload via the web UI). The appcast must be an asset of the release
# it describes, because the app polls
# https://github.com/Raters0/MacIDM/releases/latest/download/appcast.xml
# which always redirects to the newest published release's asset.
#
# Output (default .build/release/, transient):
#   MacIDM-v<version>-macos-development.app.zip  (EdDSA-signed enclosure)
#   appcast.xml
#   SHA256SUMS.txt

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
sparkle_bin="$repository_root/.build/artifacts/sparkle/Sparkle/bin"
output_directory="${MACIDM_RELEASE_OUTPUT_DIRECTORY:-$repository_root/.build/release}"
public_key_path="${MACIDM_SPARKLE_PUBKEY_PATH:-$repository_root/scripts/sparkle-eddsa-public-key.txt}"
minimum_system_version="13.0"

if [ ! -x "$sparkle_bin/sign_update" ]; then
  echo "[package-update-release] sign_update not found at $sparkle_bin/sign_update" >&2
  echo "[package-update-release] run 'swift package resolve' once so Sparkle's tools are fetched" >&2
  exit 1
fi

# Failure guard: signing without the key would publish updates no app can
# verify. The key file also feeds the build script's Info.plist injection.
if [ ! -r "$public_key_path" ]; then
  echo "[package-update-release] Sparkle EdDSA public key missing at $public_key_path" >&2
  exit 1
fi
public_key="$(tr -d '[:space:]' < "$public_key_path")"

echo "[package-update-release] building app bundle..." >&2
application_path="$(bash "$repository_root/scripts/build-debug-app.sh")"
if [ ! -d "$application_path" ]; then
  echo "[package-update-release] expected app bundle not found: $application_path" >&2
  exit 1
fi

info_plist="$application_path/Contents/Info.plist"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")"

# Sparkle compares sparkle:version against the host bundle's
# CFBundleVersion; the build script pins both to the marketing version.
if [ "$bundle_version" != "$version" ]; then
  echo "[package-update-release] CFBundleVersion ($bundle_version) != CFBundleShortVersionString ($version); fix scripts/build-debug-app.sh" >&2
  exit 1
fi

zip_name="MacIDM-v${version}-macos-development.app.zip"
zip_path="$output_directory/$zip_name"
appcast_path="$output_directory/appcast.xml"
sums_path="$output_directory/SHA256SUMS.txt"
mkdir -p "$output_directory"
rm -f "$zip_path" "$appcast_path" "$sums_path"

echo "[package-update-release] archiving $application_path" >&2
# ditto preserves symlinks and code-signing metadata inside the archive;
# Sparkle's own packaging guidance for app updates.
ditto -c -k --sequesterRsrc --keepParent "$application_path" "$zip_path"

echo "[package-update-release] signing archive with Sparkle EdDSA key..." >&2
signature="$("$sparkle_bin/sign_update" "$zip_path")"
ed_signature="$(printf '%s' "$signature" | sed -E 's/.*edSignature="([^"]+)".*/\1/')"
zip_length="$(printf '%s' "$signature" | sed -E 's/.*length="([0-9]+)".*/\1/')"
if [ -z "$ed_signature" ] || [ -z "$zip_length" ]; then
  echo "[package-update-release] sign_update produced no usable signature (is the private key in the login Keychain? run Sparkle's generate_keys)" >&2
  exit 1
fi

pub_date="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S %z')"
cat > "$appcast_path" <<EOF
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/" version="2.0">
    <channel>
        <title>MacIDM</title>
        <link>https://github.com/Raters0/MacIDM</link>
        <description>MacIDM 最新发布</description>
        <language>zh-Hans</language>
        <item>
            <title>MacIDM ${version}</title>
            <pubDate>${pub_date}</pubDate>
            <sparkle:releaseNotesLink>https://github.com/Raters0/MacIDM/releases/tag/v${version}</sparkle:releaseNotesLink>
            <enclosure
                url="https://github.com/Raters0/MacIDM/releases/download/v${version}/${zip_name}"
                sparkle:version="${bundle_version}"
                sparkle:shortVersionString="${version}"
                sparkle:minimumSystemVersion="${minimum_system_version}"
                type="application/octet-stream"
                sparkle:edSignature="${ed_signature}"
                length="${zip_length}"
            />
        </item>
    </channel>
</rss>
EOF
xmllint --noout "$appcast_path"

# Same checksum document shape as the existing manual releases.
( cd "$output_directory" && shasum -a 256 "$zip_name" appcast.xml > SHA256SUMS.txt )

echo "[package-update-release] output:" >&2
ls -l "$zip_path" "$appcast_path" "$sums_path" >&2
cat >&2 <<EOF

[package-update-release] publish manually (requires the repository owner):

  gh release create "v${version}" "$zip_path" "$appcast_path" "$sums_path" \\
    --title "MacIDM v${version}" \\
    --notes "See docs for changes."

For an existing release, upload with: gh release upload "v${version}" "$zip_path" "$appcast_path" "$sums_path" --clobber
EOF
