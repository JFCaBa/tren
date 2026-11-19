#!/usr/bin/env bash
# Renders header-b.html to the App Store header PNG (5244x2950, no alpha).
set -euo pipefail
cd "$(dirname "$0")"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
"$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 --virtual-time-budget=8000 \
  --window-size=5244,2950 --screenshot="$PWD/header-b-raw.png" "file://$PWD/header-b.html" >/dev/null 2>&1
magick header-b-raw.png -alpha remove -alpha off PNG24:header-b-5244x2950.png && rm header-b-raw.png
magick identify -format "%f %w %h opaque=%[opaque]\n" header-b-5244x2950.png
"$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 --virtual-time-budget=8000 \
  --window-size=1024,500 --screenshot="$PWD/feature-b-raw.png" "file://$PWD/feature-b.html" >/dev/null 2>&1
magick feature-b-raw.png -alpha remove -alpha off PNG24:feature-b-1024x500.png && rm feature-b-raw.png
magick identify -format "%f %w %h opaque=%[opaque]\n" feature-b-1024x500.png
