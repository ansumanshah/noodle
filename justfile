# Noodle workspace tasks. Engine recipes also run in the standalone release tree.
import "engine.just"

[private]
workspace:
    @just --list

# Assemble and ad-hoc sign build/Noodle.app.
app: resources
    scripts/make-app.sh

# Capture the website's product screens from demo mode (see scripts/capture-site-shots.sh).
site-shots *names: app
    scripts/capture-site-shots.sh {{names}}

# App tests without the render suite (PageRenderTests, about 4 of the 5 minutes): the inner loop for non-visual changes.
test-app-fast:
    NOODLE_NO_ACTIVATE=1 swift test --package-path app --skip PageRenderTests

# One e2e group from tests/e2e-groups.txt (each under 10 minutes): just e2e-group kube
e2e-group name: daemon tools
    scripts/e2e-group.sh {{name}}

# The whole pre-release pass in order, one summary file: just gate
gate:
    scripts/release-gate.sh

# Run app Swift tests, including offscreen render tests.
test-app:
    NOODLE_NO_ACTIVATE=1 swift test --package-path app

# Real native MLX serving from a repository-owned scratch container. Downloads on first use.
test-models-mlx-workloads: app tools
    NOODLE_HOME="$PWD/build/models-mlx/inference-home" build/Noodle.app/Contents/Helpers/noodle model pull qwen3-0.6b-mlx
    python3 app/tests/models-mlx-workloads.py

# Exercise kernel-source packaging with fixtures.
test-release-source:
    app/tests/release-source.sh

# Local release pipeline: plan, build, dmg, source, feed, verify, notarize.
release step="plan":
    scripts/release.sh {{step}}

# Build and test the engine from an isolated HEAD export or a prepared preview.
engine-alone *tree:
    scripts/check-engine-alone.sh {{tree}}

# Prepare the complete open-source candidate without history or local settings.
preview-source directory:
    bash scripts/preview-source.sh "{{directory}}"

# Verify the complete source export using a disposable local directory.
test-source-preview:
    bash tests/source-preview.sh

# Static checks via hk (hk.pkl, maintainer checkout only); elsewhere shellcheck at error severity.
check:
    if [ -f hk.pkl ]; then hk check; else shellcheck -S error scripts/*.sh tests/*.sh; fi

# Remove app build output in addition to the engine's clean recipe.
clean-app:
    swift package --package-path app clean || true
    rm -rf app/.build

# Engine benchmark on a throwaway Noodle home at 2 CPUs and 8 GiB. Pass flags: just bench --quick --suite api
bench *flags: daemon tools
    #!/usr/bin/env bash
    set -euo pipefail
    home=$(mktemp -d /tmp/noodle-bench.XXXXXX)
    printf '{"cpus":2,"memory_mib":8192}' > "$home/vm.json"
    NOODLE_HOME="$home" NOODLE_RESOURCES="$PWD/build/resources" "$(swift build -c {{config}} --show-bin-path)/noodled" > "$home/daemon.log" 2>&1 &
    daemon=$!
    trap 'kill "$daemon" 2>/dev/null || true; wait "$daemon" 2>/dev/null || true; rm -rf "$home"' EXIT
    deadline=$((SECONDS + 15))
    until curl -fs --max-time 1 --unix-socket "$home/run/docker.sock" http://localhost/_ping >/dev/null; do
        if (( SECONDS >= deadline )) || ! kill -0 "$daemon" 2>/dev/null; then
            echo "bench: Docker API did not become ready" >&2
            tail -20 "$home/daemon.log" >&2
            exit 1
        fi
        sleep 0.05
    done
    python3 bench/engine_bench.py run --engine noodle --host "unix://$home/run/docker.sock" --proc noodled {{flags}}
