#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2086
# E2E checks: managed-kubernetes. Sourced by tests/e2e.sh; do not run directly.

# ===================================================================== checks: managed Kubernetes (k8s lane)
# Managed single-node k3s via `noodle kubernetes`. The checks run in file order and share one cluster:
# k8s-start-ready creates it, k8s-delete-leaves-nothing removes it. Select them together: tests/e2e.sh k8s
# Real kubectl (pinned, SHA-256 checked, cached in build/tools) and a temp HOME with a sentinel ~/.kube/config.
# Env: NOODLE_BIN (the noodle CLI), K8S_KUBECTL (skip the download), E2E_K8S_TIMEOUT (default 900, per check).
K8S_KUBECTL_VERSION=v1.37.2
K8S_KUBECTL_SHA256=55701af0d51815ee335f240e48acf0959c3c23017ed3fa816e880c4a92bae581
K8S_API_PORT=$(port 70)
K8S_LB_PORT=$(port 71)
K8S_PF_PORT=$(port 76)
K8S_HOME=$WORK/k8shome
K8S_STATE=$WORK/k8s-state
K8S_NOODLE=${NOODLE_BIN:-}
if [ -z "$K8S_NOODLE" ]; then
  for c in "$ROOT/.build/release/noodle" "$ROOT/build/Noodle.app/Contents/MacOS/noodle" "$ROOT/.build/debug/noodle"; do
    [ -x "$c" ] && K8S_NOODLE=$c && break
  done
fi

nk() { # the noodle CLI with the temp HOME, the e2e daemon and the docker CLI we test with
  HOME=$K8S_HOME PATH="$K8S_STATE/bin:$(dirname "$DOCKER"):$PATH" NOODLE_NO_LAUNCHCTL=1 "$K8S_NOODLE" kubernetes "$@"
}
kc() { HOME=$K8S_HOME KUBECONFIG="$NOODLE_HOME/kubernetes/kubeconfig" "$KUBECTL" "$@"; }
k8s_prepare() {
  [ -x "$K8S_NOODLE" ] || skip "noodle CLI not built (swift build --product noodle, or set NOODLE_BIN)"
  mkdir -p "$K8S_HOME/.kube" "$K8S_STATE"
  if [ ! -f "$K8S_HOME/.kube/config" ]; then
    printf 'apiVersion: v1\nkind: Config\nclusters:\n- cluster:\n    server: https://10.255.255.1:6443\n  name: sentinel\ncontexts:\n- context:\n    cluster: sentinel\n    user: sentinel\n  name: sentinel\ncurrent-context: sentinel\nusers:\n- name: sentinel\n  user:\n    token: not-a-real-token\n' >"$K8S_HOME/.kube/config"
    cp "$K8S_HOME/.kube/config" "$K8S_STATE/kube-config.orig"
  fi
  KUBECTL=${K8S_KUBECTL:-$ROOT/build/tools/kubectl-$K8S_KUBECTL_VERSION}
  if [ ! -x "$KUBECTL" ]; then
    local tmp; tmp=$(mktemp "${TMPDIR:-/tmp}/kubectl.XXXXXX")
    curl -fsSL --max-time 300 -o "$tmp" "https://dl.k8s.io/release/$K8S_KUBECTL_VERSION/bin/darwin/arm64/kubectl" || { rm -f "$tmp"; echo "kubectl download failed"; return 1; }
    [ "$(shasum -a 256 "$tmp" | awk '{print $1}')" = "$K8S_KUBECTL_SHA256" ] || { rm -f "$tmp"; echo "kubectl SHA-256 mismatch"; return 1; }
    mkdir -p "$(dirname "$KUBECTL")"; chmod +x "$tmp"; mv "$tmp" "$KUBECTL"
  fi
  # `noodle kubernetes use-context` edits the kubeconfig through a kubectl on PATH; the pinned one is not named kubectl.
  mkdir -p "$K8S_STATE/bin"; ln -sf "$KUBECTL" "$K8S_STATE/bin/kubectl"
}
k8s_ready() {
  local n=0
  while [ $n -lt 30 ]; do
    # a fresh cluster accepts pods only once its controllers have created the default service account
    if [ "$(kc get nodes --no-headers 2>/dev/null | awk '{print $2}')" = Ready ] && kc get serviceaccount default >/dev/null 2>&1; then return 0; fi
    sleep 2; n=$((n + 1))
  done
  echo "k8s not reachable from the host: $(kc get nodes 2>&1 | head -2)"
  echo "container: $(d inspect -f '{{.State.Status}} ports={{json .NetworkSettings.Ports}}' noodle-k3s 2>&1 | cut -c1-300)"
  echo "listeners: $(lsof -nP -iTCP:"$K8S_API_PORT" -sTCP:LISTEN 2>&1 | tail -2)"
  return 1
}
k8s_apply_web() {
  kc get deploy web >/dev/null 2>&1 && return 0
  kc create deployment web --image=nginx:alpine --port=80 >/dev/null
  kc expose deployment web --type=LoadBalancer --port="$K8S_LB_PORT" --target-port=80 >/dev/null
  kc rollout status deployment/web --timeout=300s >/dev/null
}
noodled_pid() {
  local p
  for p in $(lsof -t "$SOCK" 2>/dev/null); do
    if ps -p "$p" -o comm= 2>/dev/null | grep -q 'noodled$'; then echo "$p"; return 0; fi
  done
}
k8s_footprint() { # label: noodled physical footprint, appended to $E2E_K8S_FP_OUT when set
  local pid line
  pid=$(noodled_pid)
  [ -n "$pid" ] || return 0
  line=$(footprint -p "$pid" 2>/dev/null | awk '/Footprint:/ {for (i=1;i<NF;i++) if ($i=="Footprint:") {print $(i+1) $(i+2); exit}}')
  echo "footprint $1 pid=$pid ${line:-unknown}"
  [ -z "${E2E_K8S_FP_OUT:-}" ] || echo "$1 ${line:-unknown}" >>"$E2E_K8S_FP_OUT"
}
k8s_why() { # evidence for a cluster that went away
  echo "state: $(d inspect -f '{{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} err={{.State.Error}}' noodle-k3s 2>&1 | cut -c1-300)"
  echo "status: $(nk status 2>&1 | head -3 | tr '\n' '|')"
  echo "host kubectl: $(kc get nodes 2>&1 | head -2 | tr '\n' '|')"
  echo "in-container: $(d exec noodle-k3s kubectl get nodes,pods -A 2>&1 | head -12 | tr '\n' '|')"
  echo "reader: $(kc describe pod reader 2>&1 | tail -6 | tr '\n' '|')"
  d logs --tail 6 noodle-k3s 2>&1 | cut -c1-200
}
k8s_port_open() { nc -z -w 2 127.0.0.1 "$1"; }

t_k8s_nothing_until_start() {
  k8s_prepare
  fails d image inspect "rancher/k3s"
  eq "$(d ps -a -q --filter name=noodle-k3s | wc -l | tr -d ' ')" 0
  [ ! -e "$NOODLE_HOME/kubernetes" ] || { echo "state exists before start"; return 1; }
  k8s_footprint before-start
  exit_is 3 nk status
  eq "$(nk status)" "Kubernetes: not created. \`noodle kubernetes start\` creates and starts it."
  fails k8s_port_open "$K8S_API_PORT"
}

t_k8s_refuses_unmanaged_container() {
  k8s_prepare
  d rm -f noodle-k3s >/dev/null 2>&1 || true
  d run -d --name noodle-k3s "$IMG" sleep 600 >/dev/null
  local id; id=$(d inspect -f '{{.Id}}' noodle-k3s)
  exit_is 1 nk start
  has "$(nk start 2>&1 || true)" "was not created by Noodle"
  has "$(nk stop 2>&1 || true)" "was not created by Noodle"
  has "$(nk delete --yes 2>&1 || true)" "was not created by Noodle"
  exit_is 1 nk stop
  exit_is 1 nk delete --yes
  eq "$(d inspect -f '{{.Id}} {{.State.Running}}' noodle-k3s)" "$id true"
  [ ! -e "$NOODLE_HOME/kubernetes/kubeconfig" ] || { echo "kubeconfig imported from an unmanaged container"; d rm -f noodle-k3s >/dev/null; return 1; }
  d rm -f noodle-k3s >/dev/null
}

t_k8s_start_ready() {
  k8s_prepare
  nk start --api-port "$K8S_API_PORT" --ports "$K8S_LB_PORT-$((K8S_LB_PORT + 2))" --timeout 600 | tee "$K8S_STATE/start.out"
  has "$(cat "$K8S_STATE/start.out")" "Kubernetes is ready."
  k8s_ready
  eq "$(nk kubeconfig)" "$NOODLE_HOME/kubernetes/kubeconfig"
  eq "$(stat -f %Lp "$NOODLE_HOME/kubernetes/kubeconfig")" 600
  has "$(cat "$NOODLE_HOME/kubernetes/kubeconfig")" "server: https://127.0.0.1:$K8S_API_PORT"
  # loopback only: nothing listens on a wildcard or LAN address for the API or forwarded ports
  local listeners; listeners=$(lsof -nP -iTCP:"$K8S_API_PORT" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $9}' | sort -u)
  eq "$listeners" "127.0.0.1:$K8S_API_PORT"
  lacks "$(lsof -nP -iTCP:"$K8S_LB_PORT" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $9}')" '*:'
  eq "$(cat "$K8S_HOME/.kube/config")" "$(cat "$K8S_STATE/kube-config.orig")"
  has "$(nk status)" "Kubernetes: running"
}

t_k8s_start_is_idempotent() {
  k8s_prepare
  local id1 id2
  id1=$(d inspect -f '{{.Id}}' noodle-k3s)
  nk start --api-port "$K8S_API_PORT" --ports "$K8S_LB_PORT-$((K8S_LB_PORT + 2))" | tee "$K8S_STATE/start2.out"
  has "$(cat "$K8S_STATE/start2.out")" "already running"
  id2=$(d inspect -f '{{.Id}}' noodle-k3s)
  eq "$id2" "$id1"
  nk start | grep -q "already running"      # no flags: the stored settings are kept
  eq "$(d ps -a -q --filter name=noodle-k3s | wc -l | tr -d ' ')" 1
  k8s_ready
}

t_k8s_ordinary_containers_keep_working() {
  k8s_prepare
  k8s_ready
  eq "$(d run --rm "$IMG" echo ordinary)" ordinary
  local p; p=$(port 77)
  serve e2e-k8s-plain -p "$p:80"
  wait_for 30 curl -sf "http://127.0.0.1:$p/"
  eq "$(http_get "http://127.0.0.1:$p/")" hi
  d rm -f e2e-k8s-plain >/dev/null
  k8s_ready
}

t_k8s_loadbalancer_on_localhost() {
  k8s_prepare
  k8s_apply_web
  wait_for 120 sh -c "curl -sf --max-time 5 http://127.0.0.1:$K8S_LB_PORT/ | grep -q 'Welcome to nginx'"
  has "$(http_get "http://127.0.0.1:$K8S_LB_PORT/")" "Welcome to nginx"
  has "$(kc get svc web -o jsonpath='{.status.loadBalancer.ingress[0].ip}')" "."
}

# Dynamic LoadBalancer publications: no --ports entry, retry conflicts, remove stale
# listeners on update/delete, and preserve bindings through a managed restart.
t_k8s_loadbalancer_any_port() {
  k8s_prepare
  k8s_apply_web
  local p q holder
  p=$(port 78); q=$(port 79); holder=e2e-k8s-port-holder
  trap 'd rm -f e2e-k8s-port-holder >/dev/null 2>&1 || true' EXIT
  serve "$holder" -p "127.0.0.1:$p:80"
  kc expose deployment web --name=dynamic-web --type=LoadBalancer --port="$p" --target-port=80 >/dev/null
  local n=0 status=""
  while [ $n -lt 60 ]; do
    status=$(nk status)
    case "$status" in *"$p/tcp: blocked"*) break ;; esac
    sleep 2; n=$((n + 1))
  done
  has "$status" "$p/tcp: blocked"
  has "$status" "already allocated"
  d rm -f "$holder" >/dev/null
  wait_for 120 sh -c "curl -sf --max-time 5 http://127.0.0.1:$p/ | grep -q 'Welcome to nginx'"
  has "$(nk status)" "$p/tcp: published"
  eq "$(lsof -nP -iTCP:"$p" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $9}' | sort -u)" "127.0.0.1:$p"
  nk stop >/dev/null
  fails k8s_port_open "$p"
  # An unrelated listener appearing during downtime must not block node boot.
  serve "$holder" -p "127.0.0.1:$p:80"
  nk start --timeout 600 >/dev/null
  k8s_ready
  n=0
  while [ $n -lt 60 ]; do
    status=$(nk status)
    case "$status" in *"$p/tcp: blocked"*) break ;; esac
    sleep 2; n=$((n + 1))
  done
  has "$status" "$p/tcp: blocked"
  d rm -f "$holder" >/dev/null
  wait_for 120 sh -c "curl -sf --max-time 5 http://127.0.0.1:$p/ | grep -q 'Welcome to nginx'"
  # The same number can also publish UDP, independently from TCP.
  kc apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: dynamic-dns
  namespace: kube-system
spec:
  type: LoadBalancer
  selector:
    k8s-app: kube-dns
  ports:
  - name: dns
    port: $p
    protocol: UDP
    targetPort: 53
EOF
  wait_for 120 sh -c "dig +time=2 +tries=1 +short @127.0.0.1 -p $p kubernetes.default.svc.cluster.local A | grep -q '^[0-9]'"
  has "$(nk status)" "$p/udp: published"
  # Restarting the daemon drops both VMs. Managed start must resume discovery.
  local pid; pid=$(noodled_pid)
  nonempty "$pid" noodled-pid
  kill -TERM "$pid"
  wait_for 40 sh -c "! kill -0 $pid 2>/dev/null"
  "$NOODLED" >>"$NOODLE_HOME/noodled.log" 2>&1 </dev/null &
  echo $! >"$WORK/noodled.pid"
  wait_for 60 curl -sf --max-time 2 --unix-socket "$SOCK" http://localhost/_ping
  nk start --timeout 600 >/dev/null
  k8s_ready
  wait_for 120 sh -c "curl -sf --max-time 5 http://127.0.0.1:$p/ | grep -q 'Welcome to nginx'"
  wait_for 120 sh -c "dig +time=2 +tries=1 +short @127.0.0.1 -p $p kubernetes.default.svc.cluster.local A | grep -q '^[0-9]'"
  kc patch service dynamic-web --type=json -p "[{\"op\":\"replace\",\"path\":\"/spec/ports/0/port\",\"value\":$q}]" >/dev/null
  wait_for 120 sh -c "curl -sf --max-time 5 http://127.0.0.1:$q/ | grep -q 'Welcome to nginx'"
  wait_for 30 sh -c "! nc -z -w 1 127.0.0.1 $p"
  kc delete service dynamic-web >/dev/null
  wait_for 30 sh -c "! nc -z -w 1 127.0.0.1 $q"
  kc delete service dynamic-dns -n kube-system >/dev/null
  local n=0
  while [ $n -lt 30 ]; do
    status=$(nk status)
    case "$status" in *"$p/udp: published"*) sleep 1; n=$((n + 1)) ;; *) break ;; esac
  done
  lacks "$status" "$p/udp: published"
  lacks "$(d inspect -f '{{json .HostConfig.PortBindings}}' noodle-k3s)" "\"$p/udp\""
  trap - EXIT
}

t_k8s_port_forward() {
  k8s_prepare
  k8s_apply_web
  kc port-forward --address 127.0.0.1 deployment/web "$K8S_PF_PORT:80" >"$K8S_STATE/pf.log" 2>&1 &
  local pf=$!
  wait_for 60 sh -c "curl -sf --max-time 5 http://127.0.0.1:$K8S_PF_PORT/ | grep -q 'Welcome to nginx'" || { kill $pf 2>/dev/null; cat "$K8S_STATE/pf.log"; return 1; }
  pkill -P $pf 2>/dev/null; kill $pf 2>/dev/null; wait $pf 2>/dev/null || true
  wait_for 15 sh -c "! nc -z -w 1 127.0.0.1 $K8S_PF_PORT"
  fails k8s_port_open "$K8S_PF_PORT"
}

t_k8s_pod_dns_resolves_service() {
  k8s_prepare
  k8s_apply_web
  local ip; ip=$(kc get svc web -o jsonpath='{.spec.clusterIP}')
  nonempty "$ip" clusterIP
  kc delete pod dnsprobe --ignore-not-found >/dev/null
  kc run dnsprobe --image=busybox:1.37 --restart=Never --command -- nslookup web.default.svc.cluster.local >/dev/null
  local n=0 phase=""
  while [ $n -lt 240 ]; do
    phase=$(kc get pod dnsprobe -o jsonpath='{.status.phase}' 2>/dev/null)
    [ "$phase" = Succeeded ] || [ "$phase" = Failed ] && break
    sleep 1; n=$((n + 1))
  done
  eq "$phase" Succeeded
  has "$(kc logs dnsprobe)" "$ip"
  kc delete pod dnsprobe >/dev/null
}

t_k8s_pvc_survives_stop_start() {
  k8s_prepare
  kc apply -f - >/dev/null <<'Y'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: keep}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 64Mi}}
---
apiVersion: v1
kind: Pod
metadata: {name: writer}
spec:
  restartPolicy: Never
  containers:
  - name: w
    image: busybox:1.37
    command: [sh, -c, "echo persisted-across-restart > /data/marker && sync"]
    volumeMounts: [{name: d, mountPath: /data}]
  volumes: [{name: d, persistentVolumeClaim: {claimName: keep}}]
Y
  local n=0 phase=""
  while [ $n -lt 240 ]; do
    phase=$(kc get pod writer -o jsonpath='{.status.phase}' 2>/dev/null) || true
    [ "$phase" = Succeeded ] || [ "$phase" = Failed ] && break
    sleep 1; n=$((n + 1))
  done
  eq "$phase" Succeeded
  kc delete pod writer >/dev/null
  nk stop
  eq "$(d inspect -f '{{.State.Running}}' noodle-k3s)" false
  exit_is 3 nk status
  nk start --timeout 600 >/dev/null
  k8s_ready
  kc apply -f - >/dev/null <<'Y'
apiVersion: v1
kind: Pod
metadata: {name: reader}
spec:
  restartPolicy: Never
  containers:
  - name: r
    image: busybox:1.37
    command: [sh, -c, "cat /data/marker"]
    volumeMounts: [{name: d, mountPath: /data}]
  volumes: [{name: d, persistentVolumeClaim: {claimName: keep}}]
Y
  n=0; phase=""
  while [ $n -lt 240 ]; do
    phase=$(kc get pod reader -o jsonpath='{.status.phase}' 2>/dev/null) || true
    [ "$phase" = Succeeded ] || [ "$phase" = Failed ] && break
    sleep 1; n=$((n + 1))
  done
  [ "$phase" = Succeeded ] || k8s_why
  eq "$phase" Succeeded
  eq "$(kc logs reader)" persisted-across-restart
  kc delete pod reader >/dev/null
  # the deployment from the earlier checks came back by itself too
  kc rollout status deployment/web --timeout=300s >/dev/null
}

t_k8s_state_survives_daemon_restart() {
  k8s_prepare
  # Runs alone too: start the cluster when the earlier checks did not (a no-op when it is already running).
  nk start --api-port "$K8S_API_PORT" --ports "$K8S_LB_PORT-$((K8S_LB_PORT + 2))" --timeout 600 >/dev/null
  k8s_ready
  # The PVC from k8s-pvc-survives-stop-start exists only in an ordered run; whatever phase it had must come back.
  local pvc; pvc=$(kc get pvc keep -o jsonpath='{.status.phase}' 2>/dev/null || true)
  kc create configmap persisted --from-literal=k=v --dry-run=client -o yaml | kc apply -f - >/dev/null
  local pid; pid=$(noodled_pid)
  nonempty "$pid" noodled-pid
  kill -TERM "$pid"
  wait_for 40 sh -c "! kill -0 $pid 2>/dev/null"
  "$NOODLED" >>"$NOODLE_HOME/noodled.log" 2>&1 </dev/null &
  echo $! >"$WORK/noodled.pid"
  wait_for 60 curl -sf --max-time 2 --unix-socket "$SOCK" http://localhost/_ping
  exit_is 3 nk status                      # the VMs went down with the daemon: stopped, data kept
  nk start --timeout 600 >/dev/null
  k8s_ready
  eq "$(kc get configmap persisted -o jsonpath='{.data.k}')" v
  eq "$(kc get pvc keep -o jsonpath='{.status.phase}' 2>/dev/null || true)" "$pvc"
}

# ---- approved Mac folders through hostPath. A new cluster turns the setting on at its first start.
k8s_hostpath_pod() { # name host-path command: runs a busybox pod with hostPath at the same path, prints its log
  kc delete pod "$1" --ignore-not-found >/dev/null 2>&1
  kc apply -f - >/dev/null <<Y
apiVersion: v1
kind: Pod
metadata: {name: $1}
spec:
  restartPolicy: Never
  containers:
  - name: c
    image: busybox:1.37
    command: [sh, -c, "$3"]
    volumeMounts: [{name: h, mountPath: /m}]
  volumes: [{name: h, hostPath: {path: "$2", type: DirectoryOrCreate}}]
Y
  local n=0 phase=""
  while [ $n -lt 240 ]; do
    phase=$(kc get pod "$1" -o jsonpath='{.status.phase}' 2>/dev/null) || true
    [ "$phase" = Succeeded ] || [ "$phase" = Failed ] && break
    sleep 1; n=$((n + 1))
  done
  [ "$phase" = Succeeded ] || { echo "pod $1: $phase"; k8s_why; return 1; }
  kc logs "$1"; kc delete pod "$1" >/dev/null
}
t_k8s_hostpath_approved_folder() {
  k8s_prepare
  eq "$(nk shared-folders)" on
  has "$(cat "$K8S_STATE/start.out")" "Kubernetes can use your shared folders"
  local b; b=$(mkbind); echo from-the-mac >"$b/hello"; echo "$b" >"$K8S_STATE/approved"
  HOME=$K8S_HOME "$K8S_NOODLE" share add "$b" >/dev/null
  b=$(HOME=$K8S_HOME "$K8S_NOODLE" share list | grep -F "$(basename "$b")")
  has "$(nk start --timeout 600)" "recreating the cluster container"
  k8s_ready
  eq "$(k8s_hostpath_pod mac-reader "$b" 'cat /m/hello && echo from-the-pod > /m/back')" from-the-mac
  eq "$(cat "$b/back")" from-the-pod
}
t_k8s_hostpath_unapproved_sees_nothing() {
  k8s_prepare
  local u; u=$(mkbind); echo secret >"$u/secret"
  eq "$(k8s_hostpath_pod mac-outsider "$u" 'ls -A /m | wc -l')" 0
  fails d exec noodle-k3s cat "$u/secret"
  [ ! -e "$u/back" ] && [ "$(ls -A "$u")" = secret ]
}
t_k8s_shared_folders_privileged_run() {
  k8s_prepare
  local b; b=$(cat "$K8S_STATE/approved") || return 1
  eq "$(d run --rm --privileged -v "$b:/x" "$IMG" cat /x/hello)" from-the-mac
  local u; u=$(mkbind); echo secret >"$u/secret"
  local msg; msg=$(d run --rm --privileged -v "$u:/x" "$IMG" cat /x/secret 2>&1) && { echo "expected refusal: $msg"; return 1; }
  has "$msg" "can bind only approved folders"
}
t_k8s_shared_folders_off() {
  k8s_prepare
  local b; b=$(cat "$K8S_STATE/approved") || return 1
  has "$(nk shared-folders off)" "no longer get Mac folders"
  eq "$(nk shared-folders)" off
  k8s_ready
  local msg; msg=$(d run --rm --privileged -v "$b:/x" "$IMG" true 2>&1) && { echo "expected refusal"; return 1; }
  has "$msg" "shares no Mac folders"
  eq "$(d run --rm --privileged "$IMG" sh -c 'grep -c virtiofs /proc/mounts || true')" 0
  eq "$(k8s_hostpath_pod mac-after-off "$b" 'ls -A /m | wc -l')" 0
  HOME=$K8S_HOME "$K8S_NOODLE" share remove "$b" >/dev/null
}

t_k8s_stop_leaves_nothing_running() {
  k8s_prepare
  nk stop | tee "$K8S_STATE/stop.out"
  eq "$(d inspect -f '{{.State.Running}}' noodle-k3s)" false
  eq "$(d ps -q --filter name=noodle-k3s | wc -l | tr -d ' ')" 0
  fails k8s_port_open "$K8S_API_PORT"
  fails k8s_port_open "$K8S_LB_PORT"
  nk stop | grep -q "already stopped"
  k8s_footprint after-stop
  # no extra host process of ours: only the daemon (and the VM helpers it owns) may remain
  eq "$(pgrep -f 'noodle kubernetes' | wc -l | tr -d ' ')" 0
  eq "$(cat "$K8S_HOME/.kube/config")" "$(cat "$K8S_STATE/kube-config.orig")"
}

t_k8s_use_context_edits_only_ours() {
  k8s_prepare
  local t=$K8S_STATE/target-config
  cp "$K8S_STATE/kube-config.orig" "$t"
  nk start --timeout 600 >/dev/null
  nk use-context --kubeconfig "$t" | grep -q "Backed up"
  eq "$(ls "$t".noodle-backup-* | wc -l | tr -d ' ')" 1
  cmp "$(ls "$t".noodle-backup-*)" "$K8S_STATE/kube-config.orig"
  eq "$(HOME=$K8S_HOME KUBECONFIG=$t "$KUBECTL" config current-context)" noodle
  has "$(HOME=$K8S_HOME KUBECONFIG=$t "$KUBECTL" config get-contexts -o name)" sentinel
  eq "$(HOME=$K8S_HOME "$KUBECTL" --kubeconfig "$t" get nodes --no-headers | awk '{print $2}')" Ready
  nk use-context --remove --kubeconfig "$t" >/dev/null
  eq "$(HOME=$K8S_HOME KUBECONFIG=$t "$KUBECTL" config get-contexts -o name)" sentinel
  eq "$(HOME=$K8S_HOME KUBECONFIG=$t "$KUBECTL" config get-clusters | tail -n +2)" sentinel
  eq "$(HOME=$K8S_HOME KUBECONFIG=$t "$KUBECTL" config view -o jsonpath='{.users[*].name}')" sentinel
  eq "$(cat "$K8S_HOME/.kube/config")" "$(cat "$K8S_STATE/kube-config.orig")"
  rm -f "$t".noodle-backup-*
}

t_k8s_delete_leaves_nothing() {
  k8s_prepare
  exit_is 2 nk delete                      # no terminal and no --yes: refuses
  [ -d "$NOODLE_HOME/kubernetes" ] || { echo "refused delete removed state"; return 1; }
  nk delete --yes | tee "$K8S_STATE/delete.out"
  eq "$(d ps -a -q --filter name=noodle-k3s | wc -l | tr -d ' ')" 0
  eq "$(d volume ls -q --filter name=noodle-k3s | wc -l | tr -d ' ')" 0
  [ ! -e "$NOODLE_HOME/kubernetes" ] || { echo "state left behind"; return 1; }
  fails k8s_port_open "$K8S_API_PORT"
  exit_is 3 nk status
  nk delete --yes | grep -q "No Kubernetes cluster to delete"
  eq "$(cat "$K8S_HOME/.kube/config")" "$(cat "$K8S_STATE/kube-config.orig")"
  cmp "$K8S_HOME/.kube/config" "$K8S_STATE/kube-config.orig"
}

