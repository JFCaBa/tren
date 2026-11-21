#!/usr/bin/env bash
# Platform collector on the VPS, run every minute from cron (GitHub's scheduled runs came only
# 2-4 times a day). It records sightings into a worktree of the `platform-data` branch and, every
# 15 minutes, publishes them there as the same single amended commit the workflow used to make.
# Setup: pipeline/vps/README.md.
set -euo pipefail

ROOT=${ANDEN_PLATFORMS_DIR:-$HOME/anden-platforms}
SRC=$ROOT/src
DATA=$ROOT/data
LOG=$ROOT/collect.log

exec 9>"$ROOT/lock"
flock -n 9 || exit 0 # a slow pass is still running

# Keep the log small: about 60 KB a day of "no changes" lines.
if [ -f "$LOG" ] && [ "$(stat -c %s "$LOG")" -gt 1000000 ]; then
  tail -n 2000 "$LOG" >"$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi
exec >>"$LOG" 2>&1

timeout 60 python3 "$SRC/pipeline/collect_platforms.py" --state "$DATA/platforms.json"

[ "${1:-}" = publish ] || [ $((10#$(date -u +%M) % 15)) = 0 ] || exit 0

cd "$DATA"
published=$(cat "$ROOT/published")
git add platforms.json
[ -f platforms-prev.json ] && git add platforms-prev.json
if ! git diff --cached --quiet; then
  git commit -q --amend --reset-author -m "platform observations"
fi
# Also retries a commit a failed push left behind.
[ "$(git rev-parse HEAD)" = "$published" ] && exit 0
# Only replace the commit last published from here: another writer must not be overwritten.
if ! timeout 120 git push -q --force-with-lease=refs/heads/platform-data:"$published" origin HEAD:refs/heads/platform-data; then
  remote=$(timeout 60 git ls-remote origin refs/heads/platform-data | cut -f1 || true)
  if [ -n "$remote" ] && [ "$remote" != "$published" ]; then
    echo "error: platform-data moved to $remote (was the manual workflow run?); not overwriting it. See pipeline/vps/README.md"
  fi
  exit 1
fi
git rev-parse HEAD >"$ROOT/published"
echo "published $(date -u +%FT%TZ)"
