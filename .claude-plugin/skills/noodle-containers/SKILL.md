---
name: noodle-containers
description: Run containers on Noodle. Use for docker run, build and Compose against the noodle context, the managed Kubernetes cluster, Linux machines, shared Mac folders, named localhost URLs, public links, image scans and importing from another engine.
---

# Noodle containers

Noodle serves the Docker Engine API, so the standard tools work unchanged. Check `noodle status --json` first (exit 3: run `noodle start`).

## Containers, builds, Compose

```sh
docker --context noodle run --rm alpine:3.22 echo hello
docker --context noodle run -d -p 127.0.0.1:8080:80 --name web nginx:alpine
docker --context noodle build -t local/demo .
docker --context noodle compose up -d
```

Always pass `--context noodle`; plain `docker` targets Noodle only when it is the default context. Images are linux/arm64. The build worker starts on the first build and stops when idle.

Done when `docker --context noodle ps --format json` shows the container in the state you wanted.

## Mac folders

An ordinary container can bind any existing directory (`-v /path:/dir`). Approval is needed only for a single-file bind, and for binds in privileged and Kubernetes containers. An unapproved single file fails with a message naming the fix.

```sh
noodle share add /absolute/path
noodle share list
```

## Names and ports

A container with a web port answers at `http://NAME.localhost`. For a dev server on the Mac itself: `noodle names add api.myapp 3000`, or `noodle dev api.myapp -- bun run dev`. `noodle names list --json` shows every name. HTTPS needs `noodle names trust` once; it opens a macOS password prompt, so ask the user to run it. `noodle container ports NAME --json` lists published ports, and `noodle container edit NAME --publish 8081:80 --env K=V` changes a container in place.

Inside a container, `host.docker.internal` reaches services on the Mac's loopback.

## Kubernetes

```sh
noodle kubernetes start --json
noodle kubernetes use-context
kubectl get nodes
```

`noodle kubernetes status --json` exits 0 in every state and reports the state in the JSON; plain `noodle kubernetes status` exits 3 when the cluster is not running or not ready. `noodle kube play file.yaml` runs a Kubernetes YAML file as plain containers with no cluster; `--down` removes them.

## Linux machines

A machine is a persistent VM with its own kernel.

```sh
noodle machine create dev --cpus 4 --memory 4G --disk 40 --share ~/Code
noodle machine shell dev -- uname -a
noodle machine list --json
```

`shell NAME -- CMD` returns the command's exit code and starts the machine if needed. The shared folder appears at `/mnt/share`. Add `--systemd` when the task needs `systemctl` (Ubuntu only).

## Other commands

| Need | Command |
| --- | --- |
| Vulnerabilities in an image | `noodle scan IMAGE --json` (`--fail-on high` exits 2 on a match) |
| Bill of materials | `noodle sbom IMAGE --output sbom.json` |
| Image layers, build history | `noodle image layers IMAGE --json`, `noodle builds list --json` |
| Pods | `noodle pod create|ps|inspect|start|stop|rm --json` |
| Copy images, volumes and containers from Docker Desktop or OrbStack | `noodle import SOURCE --list`, then `--all --dry-run`, then without `--dry-run` |
| Public HTTPS link to a container | `noodle link NAME:PORT --json` (it asks for confirmation, so a non-interactive shell also needs `--yes`, which you add only after the user approves the public link) |

`noodle link` publishes the container to the internet, so run it only when the user asks, and stop it with `noodle link stop ID` when done.

## Cleanup

Remove what the task created: `docker --context noodle rm -f NAME`, `docker --context noodle compose down`, `noodle machine delete NAME --yes`, `noodle kubernetes delete --yes`. Delete only what you created or the user named.
