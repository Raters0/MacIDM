#!/bin/bash

# Regenerates the app icon and menu-bar template icon from the approved bear
# artwork in Resources/Design. The Debug build invokes this script every time,
# so the selected artwork cannot be replaced by an older procedural icon.

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
resources_directory="$repository_root/Resources"
iconset_directory="$resources_directory/AppIcon.iconset"
app_source="$resources_directory/Design/AppIconSource.png"
menu_source="$resources_directory/Design/MenuBarIconSource.png"

if [[ ! -f "$app_source" || ! -f "$menu_source" ]]; then
    echo "error: approved icon sources are missing from Resources/Design" >&2
    exit 1
fi

mkdir -p "$iconset_directory"

while read -r filename pixels; do
    sips -z "$pixels" "$pixels" "$app_source" --out "$iconset_directory/$filename" >/dev/null
done <<'SIZES'
icon_16x16.png 16
icon_16x16@2x.png 32
icon_32x32.png 32
icon_32x32@2x.png 64
icon_128x128.png 128
icon_128x128@2x.png 256
icon_256x256.png 256
icon_256x256@2x.png 512
icon_512x512.png 512
icon_512x512@2x.png 1024
SIZES

# Crop the transparent board padding before resizing. The approved source's
# visible bounds are 34×19 inside its 36×36 canvas; scaling that square canvas
# made the bear only 7–8 points tall in the menu bar.
icon_temp_directory="$(mktemp -d /tmp/macidm-menu-icon.XXXXXX)"
cropped_menu_source="$icon_temp_directory/cropped.png"
trap 'rm -rf "$icon_temp_directory"' EXIT
sips -c 19 34 "$menu_source" --out "$cropped_menu_source" >/dev/null
sips -z 16 28 "$cropped_menu_source" --out "$resources_directory/MenuBarIcon.png" >/dev/null
sips -z 32 56 "$cropped_menu_source" --out "$resources_directory/MenuBarIcon@2x.png" >/dev/null

# `iconutil` in some local SDK combinations rejects an otherwise complete
# iconset. Modern icns entries are PNG payloads, so assemble the container
# directly and deterministically from the generated sizes.
python3 - "$iconset_directory" "$resources_directory/AppIcon.icns" <<'PYTHON'
import pathlib
import struct
import sys

iconset = pathlib.Path(sys.argv[1])
output = pathlib.Path(sys.argv[2])
entries = [
    (b"icp4", "icon_16x16.png"),
    (b"icp5", "icon_32x32.png"),
    (b"icp6", "icon_32x32@2x.png"),
    (b"ic07", "icon_128x128.png"),
    (b"ic08", "icon_128x128@2x.png"),
    (b"ic09", "icon_256x256@2x.png"),
    (b"ic10", "icon_512x512@2x.png"),
]
chunks = []
for kind, filename in entries:
    payload = (iconset / filename).read_bytes()
    chunks.append(kind + struct.pack(">I", len(payload) + 8) + payload)
body = b"".join(chunks)
output.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)
PYTHON

echo "$resources_directory/AppIcon.icns"
