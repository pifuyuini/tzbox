#!/bin/sh
set -eu
repository=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_image="$repository/Assets/AppIcon/AppIcon.png"
output="$repository/build/AppIcon.icns"

if [ ! -f "$source_image" ]; then
  echo "Missing app icon source: $source_image" >&2
  exit 1
fi
properties=$(/usr/bin/sips -g format -g pixelWidth -g pixelHeight -g hasAlpha "$source_image")
format=$(printf '%s\n' "$properties" | awk '/format:/ { print $2 }')
width=$(printf '%s\n' "$properties" | awk '/pixelWidth:/ { print $2 }')
height=$(printf '%s\n' "$properties" | awk '/pixelHeight:/ { print $2 }')
alpha=$(printf '%s\n' "$properties" | awk '/hasAlpha:/ { print $2 }')
if [ "$format" != png ] || [ "$width" != "$height" ] || [ "$width" -lt 1024 ] || [ "$alpha" != yes ]; then
  echo "AppIcon.png must be a square PNG of at least 1024 pixels with an alpha channel." >&2
  exit 1
fi

mkdir -p "$repository/tmp" "$repository/build"
icon_work=$(mktemp -d "$repository/tmp/$(date -u +%Y%m%dT%H%M%SZ)-app-icon-XXXXXX")
printf '%s\n' 'Created by TZBox build-icon.sh' > "$icon_work/.codex-tmp"
iconset="$icon_work/AppIcon.iconset"
mkdir "$iconset"

cleanup_icon_work() {
  [ -d "$icon_work" ] && [ ! -L "$icon_work" ] && [ -f "$icon_work/.codex-tmp" ] || return
  resolved=$(CDPATH= cd -- "$icon_work" && pwd -P)
  case "$resolved" in "$repository"/tmp/*) ;; *) echo "Icon work retained outside expected tmp path: $icon_work" >&2; return ;; esac
  for item in "$icon_work"/* "$icon_work"/.[!.]* "$icon_work"/..?*; do
    [ -e "$item" ] || [ -L "$item" ] || continue
    case "$item" in "$iconset"|"$icon_work/.codex-tmp") ;; *) echo "Unknown icon artifact retained: $item" >&2; return ;; esac
    [ ! -L "$item" ] || { echo "Symbolic link retained: $item" >&2; return; }
  done
  for item in "$iconset"/* "$iconset"/.[!.]* "$iconset"/..?*; do
    [ -e "$item" ] || [ -L "$item" ] || continue
    case "${item##*/}" in
      icon_16x16.png|icon_16x16@2x.png|icon_32x32.png|icon_32x32@2x.png|icon_128x128.png|icon_128x128@2x.png|icon_256x256.png|icon_256x256@2x.png|icon_512x512.png|icon_512x512@2x.png) ;;
      *) echo "Unknown icon artifact retained: $item" >&2; return ;;
    esac
    [ -f "$item" ] && [ ! -L "$item" ] || { echo "Unexpected icon artifact retained: $item" >&2; return; }
  done
  rm -f "$iconset"/*.png
  rmdir "$iconset"
  rm -f "$icon_work/.codex-tmp"
  rmdir "$icon_work"
}
trap cleanup_icon_work EXIT

for size in 16 32 128 256 512; do
  /usr/bin/sips -z "$size" "$size" "$source_image" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  /usr/bin/sips -z "$double" "$double" "$source_image" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$iconset" -o "$output"
printf '%s\n' "$output"
