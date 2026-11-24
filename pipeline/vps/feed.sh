#!/usr/bin/env bash
# Nightly timetable build on the VPS (cron of `ubuntu`, 02:30 UTC), served by nginx at
# https://api.whatplatform.uk/anden/data/. Same build_feed.py as .github/workflows/feed.yml, with the
# platforms read straight from the collector. Each run is a new generation directory; files equal to
# the ones served are hard links to them (same mtime, same ETag: apps get 304), and `current` is
# switched to it with one atomic rename. On any failure `current` is left as it was.
# Setup: pipeline/vps/README.md ("Nightly feed").
set -euo pipefail

SRC=${ANDEN_SRC:-$HOME/anden-platforms/src}
PLATFORMS=${ANDEN_PLATFORMS:-$HOME/anden-platforms/data/platforms.json}
OUT=${ANDEN_DATA_DIR:-/opt/anden/data}
BUILD=${ANDEN_BUILD:-python3 $SRC/pipeline/build_feed.py}
SEED=${ANDEN_SEED:-https://jfcaba.github.io/tren} # previous publication before the first run here
OUT=$(cd "$OUT" && pwd -P) # absolute: the `current` symlink stores this path
LOG=$OUT/feed.log

stamp() { date -u +%FT%TZ; }

exec 9>"$OUT/lock"
if ! flock -n 9; then
  echo "$(stamp) skipped: locked (a build is still running)" >>"$LOG"
  exit 0
fi

if [ -f "$LOG" ] && [ "$(wc -c <"$LOG")" -gt 1000000 ]; then
  tail -n 2000 "$LOG" >"$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi
exec >>"$LOG" 2>&1

step=start
gen=
published=
cleanup() { # remove an unpublished build, never the served one (a signal right after the swap)
  [ -n "$gen" ] && [ -z "$published" ] && [ "$(readlink "$OUT/current" 2>/dev/null)" != "$gen" ] && rm -rf "$gen"
  return 0
}
trap cleanup EXIT
trap 'echo "$(stamp) error: $step failed"' ERR

echo "$(stamp) start"
prev=$SEED
[ -f "$OUT/current/index.json" ] && prev="file://$OUT/current"

step=build
gen=$(mktemp -d "$OUT/gen.XXXXXX")
# shellcheck disable=SC2086 # BUILD is a command line
PYTHONDONTWRITEBYTECODE=1 $BUILD --out "$gen" --platforms "$PLATFORMS" --previous-base "$prev"

step=check
test -s "$gen/index.json"

step=link
if [ -d "$OUT/current" ]; then
  (cd "$gen" && find . -type f) | while IFS= read -r f; do
    old="$OUT/current/$f"
    if [ -f "$old" ] && cmp -s "$gen/$f" "$old"; then ln -f "$old" "$gen/$f"; fi
  done
fi
chmod -R a+rX "$gen"

step=publish
old_gen=$(readlink "$OUT/current" 2>/dev/null || true)
ln -sfn "$gen" "$OUT/current.new"
python3 -c 'import os, sys; os.replace(sys.argv[1], sys.argv[2])' "$OUT/current.new" "$OUT/current"
published=1

step=prune
for d in "$OUT"/gen.*; do
  # keep the generation served until now: a client may still be reading it
  [ "$d" = "$gen" ] || [ "$d" = "$old_gen" ] || rm -rf "$d"
done

echo "$(stamp) ok $(find "$gen/feeds" -name '*.json' 2>/dev/null | wc -l | tr -d ' ') núcleos"
