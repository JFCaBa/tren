# Platform collector on the VPS

`collect.sh` replaces the scheduled GitHub workflow (`.github/workflows/platforms.yml`, now manual
only): GitHub ran it 2-4 times a day instead of every 10 minutes, too rarely to learn the usual
platform of most trains. On the VPS it runs every minute and publishes to `platform-data` every
15 minutes. The nightly feed build reads that branch as before.

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
