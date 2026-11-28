#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2086
# E2E checks: established connections that survive network changes. Sourced by tests/e2e.sh; do not run directly.

parity_conn_server_ready() { parity_d exec e2e-conn-server sh -c 'netstat -lnt | grep -q ":9000 .*LISTEN"'; }

parity_conn() { # peer|host churn|network; one connection only, with bidirectional traffic throughout
  command -v python3 >/dev/null || skip "python3 required"
  local kind=$1 change=$2 p ip
  p=$(port 86)
  parity_d network create e2e-conn-main >/dev/null
  parity_d network create e2e-conn-other >/dev/null
  parity_d run -d --name e2e-conn-server --network e2e-conn-main -p "127.0.0.1:$p:9000" "$IMG" \
    nc -l -p 9000 -e /bin/cat >/dev/null
  wait_for 10 parity_conn_server_ready
  ip=$(parity_d inspect -f '{{(index .NetworkSettings.Networks "e2e-conn-main").IPAddress}}' e2e-conn-server | noaddr)
  nonempty "$ip" peer-ip
  parity_d run -d --name e2e-conn-client --network e2e-conn-main "$IMG" sleep 600 >/dev/null
  python3 - "$DOCKER" "$IMG" "$kind" "$change" "$p" "$ip" <<'PYCONN'
import os, select, socket, subprocess, sys, threading, time

docker, image, kind, change, port, ip = sys.argv[1:]
client = None
sock = None
stop = threading.Event()
condition = threading.Condition()
progress = [0]
errors = []

def run(*args):
    subprocess.run([docker, *args], check=True, timeout=30, stdout=subprocess.DEVNULL)

try:
    if kind == 'host':
        sock = socket.create_connection(('127.0.0.1', int(port)), timeout=5)
        sock.settimeout(5)
        read_fd = sock.fileno()
        def send(data):
            sock.sendall(data)
    else:
        client = subprocess.Popen([docker, 'exec', '-i', 'e2e-conn-client', 'nc', ip, '9000'],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        read_fd = client.stdout.fileno()
        def send(data):
            client.stdin.write(data)
            client.stdin.flush()

    def exchange():
        try:
            while not stop.is_set():
                payload = ('sequence-%06d\n' % progress[0]).encode()
                send(payload)
                received = b''
                deadline = time.monotonic() + 5
                while len(received) < len(payload):
                    remaining = deadline - time.monotonic()
                    if remaining <= 0 or not select.select([read_fd], [], [], remaining)[0]:
                        raise AssertionError('established stream stalled')
                    part = os.read(read_fd, len(payload) - len(received))
                    if not part:
                        raise AssertionError('established stream closed')
                    received += part
                if received != payload:
                    raise AssertionError('echo bytes changed: %r' % received)
                with condition:
                    progress[0] += 1
                    condition.notify_all()
                stop.wait(0.02)
        except Exception as error:
            with condition:
                errors.append(error)
                condition.notify_all()

    def flowing():
        with condition:
            previous = progress[0]
            deadline = time.monotonic() + 8
            while progress[0] <= previous and not errors:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise AssertionError('no bytes after network change')
                condition.wait(remaining)
            if errors:
                raise errors[0]

    worker = threading.Thread(target=exchange, daemon=True)
    worker.start()
    flowing()  # Establish the stream before the first mutation; never reconnect.
    for round_number in range(4):
        if change == 'network':
            name = 'e2e-conn-new-%d' % round_number
            run('network', 'create', name)
            flowing()
            # Guest bridges are lazy: attach a container to materialize the new one.
            run('run', '-d', '--name', 'e2e-conn-new-member', '--network', name, image, 'sleep', '600')
            flowing()
            run('stop', '-t', '1', 'e2e-conn-new-member')
            flowing()
            run('rm', 'e2e-conn-new-member')
            flowing()
            run('network', 'rm', name)
            flowing()
        else:
            for network in ('e2e-conn-main', 'e2e-conn-other'):
                name = 'e2e-conn-churn'
                run('run', '-d', '--name', name, '--network', network, image, 'sleep', '600')
                flowing()
                run('stop', '-t', '1', name)
                flowing()
                run('rm', name)
                flowing()
    flowing()
    print('echoed %d messages on the original connection' % progress[0])
finally:
    stop.set()
    if sock is not None:
        sock.close()
    if client is not None:
        client.terminate()
        try:
            client.wait(timeout=5)
        except subprocess.TimeoutExpired:
            client.kill()
            client.wait(timeout=5)
PYCONN
}

t_conn_survives_peer_churn() { parity_conn peer churn; }

t_conn_survives_published_churn() { parity_conn host churn; }

t_conn_survives_peer_network_create() { parity_conn peer network; }

t_conn_survives_published_network_create() { parity_conn host network; }

# A published TCP connection that carries nothing for 90 s must still be open and usable.
t_port_publish_idle_connection_survives_90s() {
  command -v python3 >/dev/null || skip "python3 required"
  local p; p=$(port 220)
  d run -d --name e2e-idle90 -p "127.0.0.1:$p:9000" "$IMG" nc -l -p 9000 -e /bin/cat >/dev/null
  wait_for 10 sh -c "'$DOCKER' exec e2e-idle90 sh -c 'netstat -lnt | grep -q \":9000 .*LISTEN\"'"
  python3 - "$p" <<'PY'
import socket, sys, time
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=10)
s.sendall(b"before\n"); assert s.recv(16) == b"before\n"
time.sleep(90)
s.sendall(b"after\n"); s.settimeout(10)
assert s.recv(16) == b"after\n", "connection dropped while idle"
PY
}
