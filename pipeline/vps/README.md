# Platform collector on the VPS

`collect.sh` replaces the scheduled GitHub workflow (`.github/workflows/platforms.yml`, now manual
only): GitHub ran it 2-4 times a day instead of every 10 minutes, too rarely to learn the usual
platform of most trains. On the VPS it runs every minute and publishes to `platform-data` every
15 minutes. The nightly feed build reads that branch as before.

**`platform-data` is a permanent data branch: never delete, merge or rebase it** — see
[docs/platform-data.md](../../docs/platform-data.md) (what it holds, who reads it, how to restore it).

Layout (user `ubuntu` on the VPS, no sudo):

- `~/anden-platforms/src`: clone of this repo over SSH with a write deploy key
  (`~/.ssh/anden_platforms`, host alias `github-anden` in `~/.ssh/config`).
- `~/anden-platforms/data`: detached worktree of `platform-data`.
- `~/anden-platforms/published`: SHA last pushed (lease for the next push).
- Log: `~/anden-platforms/collect.log`.

Setup:

```sh
ssh-keygen -t ed25519 -N '' -f ~/.ssh/anden_platforms -C anden-platforms-vps
printf 'Host github-anden\n  HostName github.com\n  User git\n  IdentityFile ~/.ssh/anden_platforms\n  IdentitiesOnly yes\n' >> ~/.ssh/config
# on a machine with gh: gh repo deploy-key add anden_platforms.pub --allow-write -t "VPS platform collector"
mkdir -p ~/anden-platforms && cd ~/anden-platforms
git clone -q github-anden:JFCaBa/tren.git src
git -C src fetch -q origin platform-data
git -C src worktree add -q --detach ../data FETCH_HEAD
git -C data config user.name "anden-platforms"
git -C data config user.email "noreply@users.noreply.github.com"
git -C data rev-parse HEAD > published
(crontab -l; echo '* * * * * $HOME/anden-platforms/src/pipeline/vps/collect.sh') | crontab -
```

If the log says `platform-data moved`, someone else pushed to the branch (the manual workflow):
check that its data is not newer than ours, then `git -C ~/anden-platforms/data ls-remote origin
refs/heads/platform-data | cut -f1 > ~/anden-platforms/published` to let the next pass replace it.

Update the script: `git -C ~/anden-platforms/src pull --ff-only`.

## Nightly feed (`feed.sh`)

Builds the timetables (`index.json`, `feeds/<núcleo>.json`, `feed.json`) every night with the same
`build_feed.py` as `.github/workflows/feed.yml`, reading the platforms from the collector's local
`data/platforms.json`. nginx serves them at `https://api.whatplatform.uk/anden/data/`
(`deploy/nginx/whatplatform.uk.conf` in the platform repo). GitHub Pages keeps being published too
until the app that reads from our server is adopted.

- `/opt/anden/data/gen.*`: one directory per build; the current and the previous one are kept.
  Files change every night (`generated_at`), so apps get 304 during the day and one download a night.
- `/opt/anden/data/current`: symlink to the served build, switched with one atomic rename. If the
  build fails it is left as it was; the first run compares against GitHub Pages.
- Log: `/opt/anden/data/feed.log` (no user data).

Setup (once, with sudo for the directory):

```sh
sudo install -d -o ubuntu -g ubuntu -m 755 /opt/anden/data
~/anden-platforms/src/pipeline/vps/feed.sh && tail -3 /opt/anden/data/feed.log
(crontab -l; echo '30 2 * * * $HOME/anden-platforms/src/pipeline/vps/feed.sh') | crontab -
```

The cron does not run the tests: after `git -C ~/anden-platforms/src pull --ff-only`, run
`cd ~/anden-platforms/src/pipeline && python3 -m unittest discover -s tests`.
