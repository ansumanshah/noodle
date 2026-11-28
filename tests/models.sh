#!/usr/bin/env bash
# Real host-only smoke test. Downloads the pinned model and shared engine on first use.
set -euo pipefail

[[ -x ${NOODLE_BIN:-} ]] || { echo 'Set NOODLE_BIN to the built noodle executable.' >&2; exit 2; }
root=$(mktemp -d "/tmp/noodle-models.XXXXXX")
export NOODLE_HOME="$root/home"
server=
sleep_pid=
cleanup() {
  status=$?
  "$NOODLE_BIN" model stop >/dev/null 2>&1 || true
  if [[ -n $server ]]; then kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true; fi
  if [[ -n $sleep_pid ]]; then kill "$sleep_pid" 2>/dev/null || true; wait "$sleep_pid" 2>/dev/null || true; fi
  if [[ $status != 0 && ${E2E_KEEP:-0} == 1 ]]; then
    touch "$root/.keep"
    echo "Evidence in $root" >&2
  else
    rm -rf "$root"
  fi
}
trap cleanup EXIT

n() { "$NOODLE_BIN" model "$@"; }
model=gemma4
n list --json | python3 -c 'import json,sys; assert json.load(sys.stdin) == []'
n catalog --json | python3 -c 'import json,sys; m = json.load(sys.stdin)[0]; assert m["downloadable"] and not m["installed"]'
n status --json | python3 -c 'import json,sys; assert json.load(sys.stdin)["phase"] == "stopped"'
[[ ! -e $NOODLE_HOME ]]
if n serve "$model" --workloads 0.0.0.0; then exit 1; fi
if n serve "$model" --workloads 127.0.0.1; then exit 1; fi
[[ ! -e $NOODLE_HOME ]]

printf 'not a valid model file at all\n' > "$root/bad.gguf"
if n import "$root/bad.gguf" broken; then exit 1; fi
if n import "$root/bad.gguf" ../escaped; then exit 1; fi
if [[ -n ${NOODLE_MODELS_GGUF:-} ]]; then
  mkdir -p "$NOODLE_HOME/models/weights"
  cp -c "$NOODLE_MODELS_GGUF" "$NOODLE_HOME/models/weights/$model.gguf"
fi
n pull "$model" --progress-json > "$root/pull.jsonl"
python3 - "$root/pull.jsonl" "${NOODLE_MODELS_GGUF:-}" <<'PY'
import json, pathlib, sys
events = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
assert [event["phase"] for event in events[-2:]] == ["verifying", "installed"]
assert all(event["totalBytes"] == 3349516256 for event in events)
assert all(0 <= event["receivedBytes"] <= event["totalBytes"] for event in events)
if not sys.argv[2]:
    assert any(event["phase"] == "downloading" and 0 < event["receivedBytes"] < event["totalBytes"]
               for event in events)
PY
n pull "$model"
n list --json | python3 -c 'import json,sys; m = json.load(sys.stdin)[0]; assert m["installed"] and m["bytes"] == 3349516256'
port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
n serve "$model" --port "$port" > "$root/start-1" &
first=$!
n serve "$model" --port "$port" > "$root/start-2" &
second=$!
wait "$first"
wait "$second"

n status --json | python3 -c 'import json,sys; s = json.load(sys.stdin); assert s["phase"] == "ready" and "apiKey" not in s and not s.get("namedBaseURL")'
n endpoint --json > "$root/endpoint"
python3 - "$root/endpoint" "$root/auth" "$model" "$port" <<'PY'
import json, pathlib, sys
endpoint, auth, model, port = sys.argv[1:]
data = json.loads(pathlib.Path(endpoint).read_text())
assert data["model"] == model and data["baseURL"] == f"http://127.0.0.1:{port}/v1"
assert not data.get("namedBaseURL"), "standalone model serving must not need a daemon or invent a local name"
assert len(data["apiKey"]) == 64
pathlib.Path(auth).write_text("Authorization: Bearer " + data["apiKey"] + "\n")
PY
url="http://127.0.0.1:$port/v1"
cat > "$root/chat.json" <<'JSON'
{"model":"gemma4","messages":[{"role":"user","content":"Say hello in one sentence."}],"chat_template_kwargs":{"enable_thinking":false},"stream":true,"max_tokens":32,"temperature":0}
JSON
[[ -n $(n run "$model" "Say hello in one sentence.") ]]
code=$(curl --disable --noproxy '*' -sS --max-time 5 -o /dev/null -w '%{http_code}' \
  -H 'Content-Type: application/json' --data-binary @"$root/chat.json" "$url/chat/completions")
[[ $code == 401 ]]
curl --disable --noproxy '*' -fsSN --max-time 60 -H @"$root/auth" -H 'Content-Type: application/json' \
  --data-binary @"$root/chat.json" "$url/chat/completions" > "$root/stream"
python3 - "$root/stream" <<'PY'
import json, pathlib, sys
events = [line[6:] for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if line.startswith("data: ")]
assert events[-1] == "[DONE]"
assert any(choice.get("delta", {}).get("content") for event in events[:-1]
           for choice in json.loads(event).get("choices", []))
PY
messages='{"model":"gemma4","max_tokens":64,"messages":[{"role":"user","content":"hi"}]}'
curl --disable --noproxy '*' -fsS --max-time 60 -H @"$root/auth" -H 'anthropic-version: 2023-06-01' \
  -H 'Content-Type: application/json' -d "$messages" "$url/messages" > "$root/messages.json"
python3 - "$root/messages.json" <<'PY'
import json, pathlib, sys
assert isinstance(json.loads(pathlib.Path(sys.argv[1]).read_text()).get("content"), list)
PY
if n rm "$model"; then exit 1; fi
n stop
if curl --disable --noproxy '*' -fsS --max-time 2 "$url/health" >/dev/null 2>&1; then exit 1; fi
n status --json | python3 -c 'import json,sys; assert json.load(sys.stdin)["phase"] == "stopped"'

python3 - "$root/occupied-port" <<'PY' &
import http.server, pathlib, sys
with http.server.HTTPServer(("127.0.0.1", 0), http.server.SimpleHTTPRequestHandler) as server:
    pathlib.Path(sys.argv[1]).write_text(str(server.server_port))
    server.serve_forever()
PY
server=$!
for _ in $(seq 1 50); do
  [[ -s $root/occupied-port ]] && break
  sleep 0.1
done
[[ -s $root/occupied-port ]]
if n serve "$model" --port "$(cat "$root/occupied-port")"; then exit 1; fi
kill -0 "$server"

sleep 60 &
sleep_pid=$!
printf '{"id":"stale","model":"%s","host":"127.0.0.1","port":%s,"executable":"/bin/sleep","process":{"pid":%s,"seconds":0,"microseconds":0}}' \
  "$model" "$port" "$sleep_pid" > "$NOODLE_HOME/models/session.json"
n stop
kill -0 "$sleep_pid"

n import "$NOODLE_HOME/models/weights/$model.gguf" local-copy
n rm local-copy
n rm "$model"
n list --json | python3 -c 'import json,sys; assert json.load(sys.stdin) == []'
[[ ! -S $NOODLE_HOME/run/docker.sock ]]
echo "Noodle Models host smoke passed"
