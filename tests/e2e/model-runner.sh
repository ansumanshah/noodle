#!/usr/bin/env bash
# shellcheck shell=bash
# Lead-only VM + network acceptance with the real upstream plugin. Never starts a GUI.

model_runner_prepare() {
  [[ ${E2E_MODEL_RUNNER_INTEGRATED:-0} == 1 ]] || skip 'opt in to model downloads with E2E_MODEL_RUNNER_INTEGRATED=1'
  if [[ ${NOODLE_E2E_EXTERNAL:-0} == 1 || -n ${E2E_SOCKET:-} ]]; then
    skip "model runner cases need an isolated Noodle home"
  fi
  local ctx cli upstream
  ctx=$(mkctx)
  cli=${NOODLE_BIN:-$(dirname "$NOODLED")/noodle}
  upstream=$ROOT/build/tools/cli-plugins/docker-model
  [[ -x $cli && -x $upstream ]] || skip 'build the CLI and run scripts/fetch-tools.sh for the pinned upstream plugin'
  mkdir -p "$ctx/docker/cli-plugins" "$NOODLE_HOME/tools/cli-plugins"
  cp -c "$upstream" "$NOODLE_HOME/tools/cli-plugins/docker-model" 2>/dev/null || cp "$upstream" "$NOODLE_HOME/tools/cli-plugins/docker-model"
  for plugin in docker-compose docker-buildx; do
    [[ ! -x "$ROOT/build/tools/cli-plugins/$plugin" ]] || ln -s "$ROOT/build/tools/cli-plugins/$plugin" "$ctx/docker/cli-plugins/$plugin"
  done
  python3 - "$cli" "$NOODLE_HOME" "$ctx/docker/cli-plugins/docker-model" <<'PY'
import pathlib, shlex, sys
cli, home, target = sys.argv[1:]
path = pathlib.Path(target)
path.write_text('#!/bin/sh\nexec ' + shlex.join([cli, '__tool-plugin', 'docker-model', home, target]) + ' "$@"\n')
path.chmod(0o700)
PY
  export DOCKER_CONFIG=$ctx/docker
  d model version >/dev/null || {
    echo 'Install the real Docker Model plugin before this acceptance run' >&2
    return 1
  }
  d model status --json >"$ctx/model-status.json" || {
    echo 'Model Runner discovery failed' >&2
    return 1
  }
  python3 - "$ctx/model-status.json" <<'PY'
import json, re, sys
status = json.load(open(sys.argv[1]))
assert status['running'] is True
assert re.fullmatch(r'http://host\.docker\.internal:[0-9]+/model-runner/[0-9a-f]{64}/v1/', status['endpoint'])
PY
}

t_model_runner_cli() (
  model_runner_prepare || exit 1
  local model=${E2E_DOCKER_MODEL:-hf.co/bartowski/Llama-3.2-1B-Instruct-GGUF:Q4_K_M}
  local ctx
  ctx=$(mkctx)
  trap 'd model unload --all >/dev/null 2>&1 || true; d model rm "$model" >/dev/null 2>&1 || true' EXIT
  d model ls --json >"$ctx/before.json"
  d model pull "$model"
  d model ls --json >"$ctx/after.json"
  python3 - "$ctx/after.json" "$model" <<'PY'
import json, sys
models = json.load(open(sys.argv[1]))
assert any(sys.argv[2] in model.get("tags", []) for model in models), models
PY
  d model inspect "$model" >"$ctx/inspect.json"
  nonempty "$(d model run "$model" 'hi')"
  d model ps >"$ctx/ps.txt"
  d model logs >"$ctx/logs.txt"
  d model unload --all
  d model rm "$model"
)

t_model_runner_oci_pull() (
  [[ -n ${E2E_DOCKER_OCI_MODEL:-} ]] || skip 'set E2E_DOCKER_OCI_MODEL to a public single-GGUF Hub ai/* artifact'
  model_runner_prepare || exit 1
  local model=$E2E_DOCKER_OCI_MODEL
  trap 'd model unload --all >/dev/null 2>&1 || true; d model rm "$model" >/dev/null 2>&1 || true' EXIT
  d model pull "$model"
  d model inspect "$model"
  nonempty "$(d model run "$model" 'hi')"
)

t_model_runner_compose_models() (
  model_runner_prepare || exit 1
  local model=${E2E_DOCKER_MODEL:-hf.co/bartowski/Llama-3.2-1B-Instruct-GGUF:Q4_K_M}
  local ctx
  ctx=$(mkctx)
  local dc=("$DOCKER" compose -p e2e-dmr -f "$ctx/compose.yaml")
  trap '"${dc[@]}" down -t 1 >/dev/null 2>&1 || true; d model unload --all >/dev/null 2>&1 || true; d model rm "$model" >/dev/null 2>&1 || true' EXIT
  set +x
  umask 077
  cat >"$ctx/compose.yaml" <<YAML
models:
  text-model:
    model: $model
services:
  probe:
    image: $IMG
    models: [text-model]
YAML
  cat >"$ctx/probe.sh" <<'SH'
set -eu
test -n "$TEXT_MODEL_URL"
test -n "$TEXT_MODEL_MODEL"
case "$TEXT_MODEL_URL" in
  http://host.docker.internal:*/model-runner/*/v1*) ;;
  *) echo 'Expected the authenticated host.docker.internal workload endpoint' >&2; exit 1 ;;
esac
body=$(printf '{"model":"%s","messages":[{"role":"user","content":"hi"}],"max_tokens":32,"stream":true}' "$TEXT_MODEL_MODEL")
url="${TEXT_MODEL_URL%/}/chat/completions"
origin=${TEXT_MODEL_URL%%/model-runner/*}
if wget -SO- -T 10 --header 'Content-Type: application/json' --post-data "$body" "$origin/v1/chat/completions" > /tmp/denied 2>&1; then
  echo 'Unauthenticated inference succeeded' >&2
  exit 1
fi
grep -q '401' /tmp/denied || { echo 'unauthenticated request was not refused with 401:' >&2; cat /tmp/denied >&2; exit 1; }
base=${TEXT_MODEL_URL%/v1*}
if wget -SO- -T 10 --header 'Content-Type: application/json' --post-data '{"all":true}' "$base/engines/unload" > /tmp/management 2>&1; then
  echo 'Workload model management succeeded' >&2
  exit 1
fi
grep -q '403' /tmp/management || { echo 'management was not refused with 403:' >&2; cat /tmp/management >&2; exit 1; }
wget -qO- -T 180 --header 'Content-Type: application/json' --post-data "$body" "$url"
SH
  "${dc[@]}" run --rm -T probe sh -s <"$ctx/probe.sh" >"$ctx/reply.sse"
  grep -Fq 'data: [DONE]' "$ctx/reply.sse" || { echo "no [DONE] in reply:"; head -c 2000 "$ctx/reply.sse"; return 1; }
  grep -Eq '"content"[[:space:]]*:[[:space:]]*"[^"]+' "$ctx/reply.sse"
)
