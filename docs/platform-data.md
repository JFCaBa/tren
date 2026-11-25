# The `platform-data` branch — do not delete it

`platform-data` is **not a feature branch** and must never be deleted, merged into `main`, rebased
or cleaned up. It is where Andén keeps what it has learned about which platform (vía) each train
uses. Losing it means losing months of observations: the app's platform predictions would start
from zero.

## What it holds

An orphan branch (no shared history with `main`) with a single commit, amended in place every time:

- `platforms.json`: the platform observations (≈3.5 MB, about 64 000 train/stop keys and
  140 000 sightings on 25-11-2026), built from Renfe's live vehicle positions.
- `platforms-prev.json`: the previous day's copy, a safety net against a bad run.

The commit is always called "platform observations", by `anden-platforms`. Its history is
deliberately one commit long, so `main` and the repo size stay small.

## Who writes it

The collector on the VPS (`pipeline/vps/collect.sh`, user `ubuntu`, cron every minute):

- records sightings into `~/anden-platforms/data`, a detached worktree of this branch;
- every 15 minutes amends the commit and force-pushes it with a lease on the last SHA it
  published (`~/anden-platforms/published`), so it never overwrites someone else's push.

The manual GitHub workflow `.github/workflows/platforms.yml` can also write it, but must not run
while the VPS collector is active.

Setup and the `platform-data moved` error: `pipeline/vps/README.md`.

## Who reads it

- The nightly feed on the VPS (`pipeline/vps/feed.sh`, 02:30 UTC) reads
  `~/anden-platforms/data/platforms.json` and puts the usual platform of each train into the
  timetables served at `https://api.whatplatform.uk/anden/data`.
- The GitHub workflow `.github/workflows/feed.yml` (GitHub Pages copy) fetches it from the branch.
  Without it the feeds are built with no platforms.

## Rules

- Never delete it: not on GitHub ("Delete branch" after a PR, branch cleanup), not with
  `git push origin --delete`, not with tools that prune "stale" branches.
- Never merge it into `main` or `main` into it, never rebase it, and never push to it by hand.
- A force-push to it is normal: that is how the collector publishes.
- When cleaning up branches, `main` and `platform-data` are the two permanent branches.

## If it is deleted by accident

The VPS still has the data in its worktree. Push it back from there:

```bash
ssh myairports
cd ~/anden-platforms/data
git push origin HEAD:refs/heads/platform-data   # branch gone: no lease needed
git rev-parse HEAD > ../published
```

Then check the next run in `~/anden-platforms/collect.log` says `published …`. If the VPS copy is
gone too, `platforms-prev.json` in any clone that fetched the branch is the last resort
(`git fetch origin platform-data` keeps it in `origin/platform-data` until the next prune).
