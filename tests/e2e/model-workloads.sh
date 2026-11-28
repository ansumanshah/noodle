#!/usr/bin/env bash
# shellcheck shell=bash
# Sourced by tests/e2e.sh. Uses real Docker Compose, k3s and the pinned host model.

t_model_workloads() (
  if [[ ${NOODLE_E2E_EXTERNAL:-0} == 1 || -n ${E2E_SOCKET:-} ]]; then
    skip "model workloads need an isolated Noodle daemon"
  fi
  [[ -x "$ROOT/build/tools/cli-plugins/docker-compose" ]] || skip "Compose plugin is required"
  k8s_prepare
  set +x
  umask 077
  ctx=$(mkctx)
  model=gemma4
  cluster_started=0
  bridge_container=
  dc=("$DOCKER" compose -p e2e-model -f "$ctx/compose.yaml")
  cleanup_model_workloads() {
    "$K8S_NOODLE" model stop >/dev/null 2>&1 || true
    if [[ $cluster_started == 1 ]]; then nk delete --yes >/dev/null 2>&1 || true; fi
    if [[ -f "$ctx/compose.yaml" ]]; then "${dc[@]}" down -t 1 >/dev/null 2>&1 || true; fi
    if [[ -n $bridge_container ]]; then d rm -f "$bridge_container" >/dev/null 2>&1 || true; fi
    rm -f "$ctx/connection.env" "$ctx/kube.env" "$ctx/endpoint.json"
  }
  trap cleanup_model_workloads EXIT

  if [[ -n ${NOODLE_MODELS_GGUF:-} ]]; then
    mkdir -p "$NOODLE_HOME/models/weights"
    cp -c "$NOODLE_MODELS_GGUF" "$NOODLE_HOME/models/weights/$model.gguf"
    "$K8S_NOODLE" model pull "$model"   # validate the same SHA-256 before serving the seed
  fi
  reply=$("$K8S_NOODLE" model run "$model" "Say hello in one sentence.")
  nonempty "$reply"
  "$K8S_NOODLE" model stop
  echo "Gemma replied through 'noodle model run'"

  bridge_container=$(d run -d --name e2e-model-bridge "$IMG" sleep 900)
  gateway=$(d exec "$bridge_container" awk '$2 == "host.docker.internal" { print $1; exit }' /etc/hosts)
  nonempty "$gateway"
  if d container inspect noodle-k3s >/dev/null 2>&1; then
    echo 'model workloads require a fresh managed cluster' >&2
    exit 1
  fi
  cluster_started=1
  nk start --api-port "$K8S_API_PORT" --ports "$K8S_LB_PORT-$((K8S_LB_PORT + 2))" --timeout 420
  k8s_ready

  model_port=$(python3 - "$gateway" <<'PY'
import socket, sys
with socket.socket() as listener:
    listener.bind((sys.argv[1], 0))
    print(listener.getsockname()[1])
PY
  )
  "$K8S_NOODLE" model serve "$model" --port "$model_port" --workloads "$gateway"
  "$K8S_NOODLE" model endpoint --json >"$ctx/endpoint.json"
  listeners=$(lsof -nP -iTCP:"$model_port" -sTCP:LISTEN | awk 'NR>1 {print $9}' | sort -u)
  eq "$listeners" "$gateway:$model_port"

  python3 - "$ctx" "$model_port" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
endpoint = json.loads((root / "endpoint.json").read_text())
for path, url in [("connection.env", f"http://host.docker.internal:{sys.argv[2]}/v1"),
                  ("kube.env", endpoint["workloadBaseURL"])]:
    (root / path).write_text(f"MODEL_URL={url}\nMODEL_KEY={endpoint['apiKey']}\n")
PY
  cat >"$ctx/probe.sh" <<'SH'
set -eu
body='{"model":"gemma4","messages":[{"role":"user","content":"Say hello in one sentence."}],"chat_template_kwargs":{"enable_thinking":false},"stream":true,"max_tokens":32,"temperature":0}'
if denied=$(wget -SO- -T 10 --header 'Content-Type: application/json' \
  --post-data "$body" "$MODEL_URL/chat/completions" 2>&1); then
  echo 'unauthenticated inference succeeded' >&2
  exit 1
fi
printf '%s\n' "$denied" | grep -q '401'
wget -qO- -T 40 --header "Authorization: Bearer $MODEL_KEY" --header 'Content-Type: application/json' \
  --post-data "$body" "$MODEL_URL/chat/completions"
SH
  cat >"$ctx/compose.yaml" <<YAML
services:
  probe:
    image: $IMG
    env_file: [connection.env]
YAML
  "${dc[@]}" run --rm -T probe sh -s <"$ctx/probe.sh" >"$ctx/compose.stream"
  grep -Fq 'data: [DONE]' "$ctx/compose.stream"
  grep -Eq '"content":"[^"]+' "$ctx/compose.stream"
  echo "Compose streamed with the key and rejected a request without it"

  kc create secret generic model-probe-connection --from-env-file "$ctx/kube.env"
  kc create configmap model-probe-script --from-file "$ctx/probe.sh"
  kc apply -f - <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: model-probe
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 180
  template:
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      containers:
      - name: probe
        image: $IMG
        command: ["sh", "/probe/probe.sh"]
        envFrom:
        - secretRef:
            name: model-probe-connection
        volumeMounts:
        - name: script
          mountPath: /probe
          readOnly: true
      volumes:
      - name: script
        configMap:
          name: model-probe-script
YAML
  kc wait --for=condition=complete --timeout=180s job/model-probe || {
    kc get pods -l job-name=model-probe >&2
    kc logs job/model-probe >&2
    exit 1
  }
  kc logs job/model-probe >"$ctx/kube.stream"
  grep -Fq 'data: [DONE]' "$ctx/kube.stream"
  grep -Eq '"content":"[^"]+' "$ctx/kube.stream"
  echo "k3s streamed with the key and rejected a request without it"
)
