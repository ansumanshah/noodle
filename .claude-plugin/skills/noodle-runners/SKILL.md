---
name: noodle-runners
description: Run GitHub Actions jobs on this Mac with Noodle Runners. Use to add a repository, choose a runs-on line, check that the Mac is ready for CI, see why a job is waiting or held, free disk space the runners used, or explain a build that broke after a toolchain update.
---

# Noodle runners

Noodle registers self-hosted runners per repository and gives each job a fresh runner: a container for Linux jobs, a fresh folder on the Mac for macOS jobs.

## 1. Check the Mac

```sh
noodle runners doctor --json
```

It only reads. Exit 1 means at least one check is a problem; each finding carries a one-line fix. GitHub sign-in happens in the app (Settings, Docker, GitHub Container Registry, "Also use for git clone and runners"), and the Xcode fixes need `sudo`, so hand those to the user.

Done when no finding is a problem.

## 2. Add a repository

```sh
noodle runners repos --json
noodle runners add owner/repo
noodle runners check owner/repo --json
```

`add` with no name uses the current folder's GitHub `origin`. The user must administer the repo. A public repo is refused without `--allow-public`, because anyone who can open a pull request could run code on this Mac: pass it only when the user confirms. `check` reads the workflow files and suggests a `runs-on` line per job by keyword matching; treat the result as a hint and never as an edit.

## 3. Set runs-on

| Job | Line |
| --- | --- |
| Linux (arm64) | `runs-on: [self-hosted, noodle]` |
| macOS with Xcode | `runs-on: [self-hosted, noodle-macos]`, after `noodle runners add owner/repo --macos` |
| Pin Xcode | `runs-on: [self-hosted, noodle-macos, xcode-26]` |

Windows, x86-only Linux and organisation-level runners are not supported. A macOS job runs as the user with no sandbox, so turn `--macos` on only for workflows the user trusts. Edit the workflow file, then let the user push.

## 4. Watch

```sh
noodle runners status --json
noodle runners list --json
```

`status` shows the helper, holds and start failures, `list` each repo's last job and result. A first job starts within about 10 seconds, and a warm runner takes the next one for 5 minutes after. Up to two Linux jobs and one macOS job run at once. A non-null `hold` means new jobs are waiting on this Mac: free disk fell under 10 GB (jobs resume at 15 GB) or memory pressure is critical. Fix the cause and the hold lifts by itself. A non-empty `startFailures` means runners of that kind cannot start: each entry has the `reason` and the `log` file name under `~/.noodle/runners/logs`, and `noodle runners doctor` shows the same. A job that stays queued on GitHub is usually one of these two.

Done when the job's result in `list` matches what GitHub shows.

## 5. Keep it healthy

```sh
noodle runners clean --dry-run --json
noodle runners clean
noodle runners toolchains --json
noodle runners cache --json
```

`clean` removes runner leftovers, old logs, old runner downloads, caches of repos idle past `--older-than DAYS` (default 14) and old runner images. It skips anything a running job holds and touches nothing outside the Runners folder. Show the dry run before the real one. `toolchains` lists what a macOS job sees (Xcode, Swift, Node and others) and what changed since the last job, which is the first thing to read when a build turned red with no code change. `noodle runners cache clear owner/repo` drops one repo's cache when a job fails on stale dependencies.

## Stop

`noodle runners pause owner/repo` and `resume` hold one repository. `noodle runners stop` ends idle runners, cancels a job in progress and stays off after a restart, so confirm before running it while a job is active. `noodle runners remove owner/repo` also deletes that repo's cache.
