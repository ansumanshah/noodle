# Engine benchmark

Correctness and performance for any Docker-compatible engine on one Mac. Python standard library only.

```sh
python3 bench/engine_bench.py doctor --engine orbstack
python3 bench/engine_bench.py run --engine orbstack --quick
python3 bench/engine_bench.py matrix --engines-file engines.json --passes 3
python3 bench/engine_bench.py compare build/bench/matrix-*/ --out comparison.md
python3 bench/test_engine_bench.py
python3 bench/test_devloop.py
```

`just bench` runs the suite against a throwaway Noodle home at 2 CPUs and 8 GiB.

## Suites

| Suite | Measures |
|---|---|
| `correctness` | 12 behaviour checks: exit codes, stream separation, stdin bytes, binds both ways, volumes, ports, DNS, `--network none`, stop signal, logs, cp, build |
| `lifecycle` | `run`, `run --network none`, `exec`, stdout, stdin, build uncached and cached, warm and cold pull, parallel starts |
| `api` | Create, start, wait, delete on `none` and bridge, and exec, straight over the socket |
| `storage` | Bind and volume: `fsync` write, cached read, `O_DIRECT` read, 4 KiB small-file create, stat, read, delete |
| `network` | New HTTP connections with an error count, iperf3 single and parallel when installed |
| `watch` | Host save to guest inotify event, in place and atomic: any event in the folder, and an event naming the file, with misses as failures; atomic-save visibility |
| `compose` | `up` and `down` of three services |
| `devloop` | npm install on a Mac bind mount with a warm named cache, one-line rebuild, and Compose rebuild to a new HTTP response |
| `resources` | Density, daemon and VM helper footprint, idle CPU, sleep and wake |

## Regression runs

Use `just bench --suite lifecycle,api,devloop --warmup 5 --runs 30 --io-runs 1 --devloop-runs 5 --transfer-mb 16`
with nothing else heavy running. Keep the CLI and direct API startup rows
separate. The published targets are 14.2 ms for `cli.run`, 2.55 ms for
`api.lifecycle.bridge`, and 1.26 ms for `api.lifecycle.none`. Use the
`devloop.compose-swap` result for the representative developer loop. The
separate watch, storage and reclaim jobs answer distinct questions.

Use `tests/wake.sh` for the 150 ms wake target. It verifies data-disk release
and a new guest boot ID. Measure the first cold boot separately. Use
`footprint` for daemon, app and VM-helper memory. Keep guest RSS and on-disk
agent size separate.

## Rules for a result you can publish

1. One engine up at a time, plugged in, nothing heavy running. `doctor` reports load, power and stray VMs.
2. Same CPUs and memory on every engine. `compare` prints a warning in bold when they differ.
3. Use `matrix` with at least 3 passes. It alternates order (A B, B A, A B) so drift does not favour one engine.
4. Publish `summary.json` with the report. It holds every sample and every failure.
5. Report ties. A win needs non-overlapping 95 percent intervals, a gap above 5 percent, and the same direction in every pass. A failed test counts as a loss.

`engines.json` entries take `context` or `host`, plus optional `docker`, `procs`, `settle`, and `start` with `env` for an engine the matrix starts and stops itself:

```json
{
  "noodle": {"host": "unix:///tmp/nb/run/docker.sock", "procs": ["noodled"],
             "docker": "build/tools/docker", "start": ["build/Noodle.app/Contents/MacOS/noodled"],
             "env": {"NOODLE_HOME": "/tmp/nb"}},
  "orbstack": {"context": "orbstack", "procs": ["OrbStack Helper"]}
}
```

Put `{"cpus": 2, "memory_mib": 8192}` in `$NOODLE_HOME/vm.json` to size Noodle.

## What it never does

It removes only what is in the run's own `manifest.json`, never prunes, and never removes an image it did not pull. `clean` removes what an interrupted run left. With `--host`, the run uses an isolated Docker config, so your contexts and credentials stay out of it. Reports leave out hostnames, usernames and IP addresses.

Direct runs use `build/bench-work/<engine>/`. Matrix runs use `<matrix --out>/bench-work/<engine>/`. These bind-mount folders are emptied between runs.

## Reading the numbers

- Medians, p95 and a seeded bootstrap 95 percent interval, with host load recorded per measurement.
- Storage is timed by `dd` inside the container, and small files by Node inside the container, so exec overhead stays out.
- `read.cached` is the page cache, not disk speed. `read.direct` is `O_DIRECT` where the mount allows it, and a virtiofs result may still be served by the host's cache.
- `cli.stdout` and `cli.stdin` run through `exec`, so a container start is not counted as transfer time.
- `cli.pull.warm` measures the pull path with the image present. `cli.pull.cold` includes your internet connection.
- `devloop.npm-install` runs `npm install --no-audit --no-fund` in `node:22-alpine`. Express 4.21.2, Lodash 4.17.21 and TypeScript 5.7.3 are pinned. An untimed install creates the lockfile and warms a named npm cache. Each install removes `node_modules` outside the timer, retains the lockfile, and prefers the cache. Registry access is still possible on a cache miss.
- `devloop.rebuild-one-line` warms a Node image build, then changes one app line before each timed `docker build`.
- `devloop.compose-swap` first builds and starts a web service. Each sample changes one line and times `compose up -d --build` until the published HTTP port returns the new build's unique content. A response from the old container does not count.
- Devloop uses 10 samples after 3 warmups per metric, or 2 after 1 with `--quick`. Missing buildx or Compose plugins produce skips for the affected metrics. npm cache volumes, holders, build images and Compose resources are recorded in the run manifest.

## Final run for the site

Use one Mac, one engine running at a time, on AC power. These steps run containers and are for the person holding the VM test slot. Do not run them alongside other VM tests.

1. Build the app and install the repo's Docker, buildx and Compose tools with `just app tools`. Copy `bench/engines.final.example.json` to `bench/engines.final.local.json`. Paths in that file are relative to the repo root. Check that `build/Noodle.app/Contents/MacOS/noodled` exists.
2. Give all four engines the same CPU and memory limits, for example 2 CPUs and 8 GiB. Create `/tmp/noodle-bench-final/vm.json` containing `{"cpus": 2, "memory_mib": 8192}`. Create the Podman test machine with `podman machine init --cpus 2 --memory 8192 --disk-size 30 noodle-bench` if it does not exist. Use `podman machine inspect noodle-bench` to find `ConnectionInfo.PodmanSocket.Path`, and replace `REPLACE_WITH_PODMAN_SOCKET` in the example with that path, preserving `unix://`.
3. Allow the repo's `build/` tree in each engine's file-sharing settings. The final matrix below creates bind folders in `$final_results/bench-work/<engine>/`. These folders must be writable from the guest. Verify the Docker contexts in the example match your installations.
4. Stop all engines before the first run. The matrix starts and stops Noodle and Podman through their `start` entries. OrbStack and Docker Desktop have context-only entries, so start the selected app yourself and stop it after its run. Do not pass all four engines to one matrix unless you have added lifecycle wrappers for those apps.
5. Choose a fresh output directory. Run one engine per invocation with `--passes 1`, in the order below. Start and stop the context-only engines between invocations. Before each invocation, run `doctor` with that entry's context or host while only that engine is running, then stop Noodle or Podman so the matrix can start it. Keep versions and settings fixed for all passes.

   | Pass | Engine order |
   |---|---|
   | 1 | noodle, orbstack, docker-desktop, podman |
   | 2 | podman, docker-desktop, orbstack, noodle |
   | 3 | noodle, orbstack, docker-desktop, podman |

   Repeat the matrix command below for each entry in that order, setting `engine` to the entry's ID. There are 12 invocations. Use the same `final_results` value throughout; every invocation creates a new matrix folder. Omit `--quick` for the final numbers.

```sh
final_results="build/bench/final-$(date -u +%Y%m%dT%H%M%SZ)"
engine=noodle
python3 bench/engine_bench.py matrix --engines-file bench/engines.final.local.json \
  --engines "$engine" --passes 1 --out "$final_results"
```

6. Review every `summary.json`, including skips, failures and load, and create the combined report. The publisher takes the median of valid per-pass medians, so a pass with more samples has no extra weight. Failed or partial entries are excluded with a printed reason; missing measurements stay null. Unsupported engines found in folders are ignored with a notice; explicitly selecting one with `--engines` is an error. Only Noodle, OrbStack, Docker Desktop and Podman appear in the output. Different host facts or engine versions are rejected.

```sh
python3 bench/engine_bench.py compare "$final_results" --out "$final_results/comparison.md"
python3 bench/publish_site.py "$final_results" --out website/public/data/benchmarks.json
```

The JSON remains `published: false`. Check its machine, date, engine versions and values against the raw summaries. `updated` is the latest result date, not the day the publisher runs. The output keeps the site's existing metric schema and converts seconds to milliseconds for watch, run and exec. It never copies the separate historical Noodle-only numbers into comparison rows.

Idle memory stays null: the current resource suite records footprints at other states, not the site's measurement after 60 seconds with no containers. Do not substitute the daemon's footprint or sum unrelated samples.

After reviewing the results, explicitly enable the section with:

```sh
python3 bench/publish_site.py "$final_results" --out website/public/data/benchmarks.json --publish
```

`--publish` only sets the JSON flag. It does not deploy the site. Any later invocation without that flag sets it back to false. The site shows only rows with a Noodle value and a measured comparison value. Keep the raw summaries with the report.

`bench/compare.py` and `bench/devloop.py` remain for the deeper daemon-only and 18,000-file edit-loop runs.
