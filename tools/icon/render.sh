#!/usr/bin/env bash
# Renders the Andén icon SVGs to PNG (Chrome headless for faithful SVG, ImageMagick for post-processing).
set -euo pipefail
cd "$(dirname "$0")"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
mkdir -p out
shot() { # svg width height out.png
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
    --default-background-color=00000000 --window-size="$2,$3" \
    --screenshot="$PWD/$4" "file://$PWD/$1" >/dev/null 2>&1
}
shot icon.svg 1024 1024 out/icon-raw.png
shot foreground.svg 1024 1024 out/foreground-1024.png
shot feature.svg 1024 500 out/feature-raw.png
magick out/icon-raw.png -background "#0F766E" -alpha remove -alpha off out/icon-1024.png   # App Store: no alpha
magick out/icon-1024.png -resize 512x512 out/play-512.png
magick out/feature-raw.png -background "#0F766E" -alpha remove -alpha off out/feature-1024x500.png
rm out/icon-raw.png out/feature-raw.png
for f in out/*.png; do magick identify -format "%f %w %h opaque=%[opaque]\n" "$f"; done
