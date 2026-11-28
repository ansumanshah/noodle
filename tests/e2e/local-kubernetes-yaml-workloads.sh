#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2086
# E2E checks: local-kubernetes-yaml-workloads. Sourced by tests/e2e.sh; do not run directly.

# ===================================================================== checks: local Kubernetes YAML workloads
# These checks use the public `noodle kube` CLI and verify the resulting Docker API state.
KUBE_CLI=${NOODLE_CLI:-$ROOT/.build/release/noodle}
kube_cli() { timeout -k 2 60 "$KUBE_CLI" kube "$@"; }
kube_file() { printf '%s\n' "$1" >"$WORK/$2.yaml"; echo "$WORK/$2.yaml"; }
kube_pod_absent() { [ -z "$(d ps -aq --filter "label=dev.noodle.pod=$1")" ]; }

t_kube_play_port_env() {
  [ -x "$KUBE_CLI" ] || skip "noodle CLI not built (set NOODLE_CLI)"
  local file name host
  name=e2e-kube-port-env; host=$(port 80)
  file=$(kube_file "apiVersion: v1
kind: ConfigMap
metadata:
  name: kube-port-env
data:
  greeting: world
  extra: value
---
apiVersion: v1
kind: Pod
metadata:
  name: $name
spec:
  containers:
  - name: app
    image: $IMG
    command: [sh, -c, 'printf \"%s|%s|%s\" \"\$DIRECT\" \"\$FROM_MAP\" \"\$CM_extra\" > /tmp/body; printf \"#!/bin/sh\\nprintf \\\"HTTP/1.1 200 OK\\r\\nContent-Length: 17\\r\\nConnection: close\\r\\n\\r\\n\\\"; cat /tmp/body\" > /tmp/reply; chmod +x /tmp/reply; exec nc -lk -p 80 -e /tmp/reply']
    env:
    - name: DIRECT
      value: hello
    - name: FROM_MAP
      valueFrom:
        configMapKeyRef:
          name: kube-port-env
          key: greeting
    envFrom:
    - configMapRef:
        name: kube-port-env
      prefix: CM_
    ports:
    - containerPort: 80
      hostPort: $host
  - name: peer
    image: $IMG
    command: [sleep]
    args: ['600']" kube-port-env)
  kube_cli play "$file"
  local container
  container=$name-app
  eq "$(insp "$container" '{{index .Config.Labels "dev.noodle.pod"}}')" "$name"
  # Several containers share a namespace owned by a dedicated infra container, which holds the publication.
  eq "$(insp "noodle-kube-$name-infra" '{{json .HostConfig.PortBindings}}' | python3 -c 'import json,sys; x=json.load(sys.stdin); print(x["80/tcp"][0]["HostPort"])')" "$host"
  wait_for 30 sh -c "curl -sf --max-time 2 http://127.0.0.1:$host/ | grep -q 'hello|world|value'"
  eq "$(http_get "http://127.0.0.1:$host/")" "hello|world|value"
  eq "$(d exec "$name-peer" wget -qO- http://127.0.0.1:80/)" "hello|world|value"
  kube_cli play "$file" --down
  kube_pod_absent "$name"
}

t_kube_play_hostport_defaults_to_loopback() {
  [ -x "$KUBE_CLI" ] || skip "noodle CLI not built (set NOODLE_CLI)"
  local file name host
  name=e2e-kube-hostport-lo; host=$(port 82)
  file=$(kube_file "apiVersion: v1
kind: Pod
metadata:
  name: $name
spec:
  containers:
  - name: app
    image: $IMG
    command: [sh, -c, 'exec nc -lk -p 80 -e true']
    ports:
    - containerPort: 80
      hostPort: $host" kube-hostport-lo)
  kube_cli play "$file"
  eq "$(insp "$name-app" '{{(index (index .HostConfig.PortBindings "80/tcp") 0).HostIp}}')" "127.0.0.1"
  wait_for 30 sh -c "lsof -nP -iTCP:$host -sTCP:LISTEN | grep -q 127.0.0.1"
  fails sh -c "lsof -nP -iTCP:$host -sTCP:LISTEN | grep -Eq '[*]:|\\[::\\]'"
  kube_cli play "$file" --down
  kube_pod_absent "$name"
}

t_kube_generate_round_trip() {
  [ -x "$KUBE_CLI" ] || skip "noodle CLI not built (set NOODLE_CLI)"
  local pod=e2e-kube-generate yaml file
  file=$(kube_file "apiVersion: v1
kind: Pod
metadata:
  name: $pod
spec:
  containers:
  - name: app
    image: $IMG
    command: [sleep]
    args: ['600']" kube-generate)
  kube_cli play "$file"
  yaml=$(kube_cli generate "$pod-app")
  eq "$(kube_cli generate "$pod")" "$yaml"
  has "$yaml" "$pod"
  has "$yaml" app
  file=$(kube_file "$yaml" kube-generated)
  kube_cli play "$file" --down
  kube_pod_absent "$pod"
  # The generated name remains owned by the original pod name, so it can be replayed.
  kube_cli play "$file"
  eq "$(insp "$pod-app" '{{index .Config.Labels "dev.noodle.pod"}}')" "$pod"
  kube_cli play "$file" --down
  kube_pod_absent "$pod"
}

t_kube_down_removes_owned_containers() {
  [ -x "$KUBE_CLI" ] || skip "noodle CLI not built (set NOODLE_CLI)"
  local name=e2e-kube-down file
  file=$(kube_file "apiVersion: v1
kind: Pod
metadata:
  name: $name
spec:
  containers:
  - name: sleeper
    image: $IMG
    command: [sleep, '600']" kube-down)
  kube_cli play "$file"
  eq "$(d ps -q --filter label=dev.noodle.pod="$name" | wc -l | tr -d ' ')" 1
  kube_cli play "$file" --down
  kube_pod_absent "$name"
}

t_kube_deployment_volumes_configmap() {
  [ -x "$KUBE_CLI" ] || skip "noodle CLI not built (set NOODLE_CLI)"
  local name=e2e-kube-deploy file hostpath
  hostpath=$(mkbind)
  d volume create e2e-kube-deploy-preexisting >/dev/null
  file=$(kube_file "apiVersion: v1
kind: ConfigMap
metadata:
  name: kube-deploy-cm
data:
  greeting: hello
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: e2e-kube-deploy-claim
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $name
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $name
  template:
    metadata:
      labels:
        app: $name
    spec:
      containers:
      - name: app
        image: $IMG
        command: [sh, -c, 'test \"\$FROM_CM\" = hello && sleep 600']
        env:
        - name: FROM_CM
          valueFrom:
            configMapKeyRef:
              name: kube-deploy-cm
              key: greeting
        volumeMounts:
        - name: scratch
          mountPath: /scratch
        - name: local
          mountPath: /local
        - name: persistent
          mountPath: /persistent
        - name: preexisting
          mountPath: /preexisting
      volumes:
      - name: scratch
        emptyDir: {}
      - name: local
        hostPath:
          path: $hostpath
      - name: persistent
        persistentVolumeClaim:
          claimName: e2e-kube-deploy-claim
      - name: preexisting
        persistentVolumeClaim:
          claimName: e2e-kube-deploy-preexisting" kube-deploy)
  # Freeze the manifest path here because function locals are gone when EXIT runs.
  # shellcheck disable=SC2064
  trap "kube_cli play '$file' --down >/dev/null 2>&1 || true; d volume rm -f e2e-kube-deploy-claim e2e-kube-deploy-preexisting >/dev/null 2>&1 || true" EXIT
  kube_cli play "$file"
  eq "$(d ps -q --filter label=dev.noodle.pod="$name" | wc -l | tr -d ' ')" 1
  eq "$(d volume ls -q --filter name=e2e-kube-deploy-claim | wc -l | tr -d ' ')" 1
  local container mounts
  container=$name-app
  mounts=$(insp "$container" '{{json .Mounts}}')
  has "$mounts" /scratch
  has "$mounts" /local
  has "$mounts" /persistent
  has "$mounts" /preexisting
  d exec "$container" sh -c 'echo scratch > /scratch/check; echo host > /local/check; echo pvc > /persistent/check; echo existing > /preexisting/check'
  eq "$(cat "$hostpath/check")" host
  eq "$(d exec "$container" cat /scratch/check /persistent/check /preexisting/check)" "$(printf 'scratch\npvc\nexisting')"
  kube_cli play "$file" --down
  kube_pod_absent "$name"
  eq "$(d volume ls -q --filter name=e2e-kube-deploy-claim | wc -l | tr -d ' ')" 0
  eq "$(d volume ls -q --filter name=e2e-kube-deploy-preexisting | wc -l | tr -d ' ')" 1
  d volume rm e2e-kube-deploy-preexisting >/dev/null
  trap - EXIT
}

t_kube_refuses_unsupported() {
  [ -x "$KUBE_CLI" ] || skip "noodle CLI not built (set NOODLE_CLI)"
  local file
  file=$(kube_file "apiVersion: v1
kind: Service
metadata:
  name: e2e-kube-unsupported" kube-unsupported)
  if kube_cli play "$file" >"$WORK/kube-unsupported.out" 2>&1; then
    echo "unsupported Service was accepted"; return 1
  fi
  has "$(cat "$WORK/kube-unsupported.out")" "unsupported kind"
  kube_pod_absent e2e-kube-unsupported
}

t_kube_warns_unknown_fields() {
  [ -x "$KUBE_CLI" ] || skip "noodle CLI not built (set NOODLE_CLI)"
  local name=e2e-kube-warning file
  file=$(kube_file "apiVersion: v1
kind: Pod
metadata:
  name: $name
spec:
  unsupported: ignored
  containers:
  - name: app
    image: $IMG
    command: [sleep, '600']
    unsupportedContainerField: ignored" kube-warning)
  kube_cli play "$file" >"$WORK/kube-warning.out" 2>"$WORK/kube-warning.err"
  has "$(cat "$WORK/kube-warning.err")" "warning: unsupported field $name.spec.unsupported ignored"
  has "$(cat "$WORK/kube-warning.err")" "warning: unsupported field container.unsupportedContainerField ignored"
  is_running "$name-app"
  kube_cli play "$file" --down
  kube_pod_absent "$name"
}

