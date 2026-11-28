---
name: noodle-models
description: Run local AI models with Noodle. Use to download, chat with or serve a model on this Mac, get the OpenAI-compatible base URL and key for a tool or script, call embeddings, speech, image or video endpoints, or reach the model from a container.
---

# Noodle models

Models run on the Mac itself. The container engine can stay off.

## 1. Pick and download

```sh
noodle model catalog --json
noodle model list --json
noodle model pull qwen3.5-4b
```

`catalog` is what can be pulled, `list` is what is installed. Check the size in the catalog against free memory before pulling a large one: `qwen3.5-4b` is the safe pick on 16 GB, `bonsai2-27b` is stronger but needs about 10 GB free. A local file works too: `noodle model import file.gguf my-id`.

## 2. One prompt, no server

```sh
noodle model run qwen3.5-4b "Why does nginx return 502?"
echo "Summarise this" | noodle model run qwen3.5-4b
```

The answer is on stdout. The first run downloads the model.

## 3. Serve it

```sh
noodle model serve qwen3.5-4b
noodle model endpoint --json
```

`endpoint` gives the base URL, the model ID and the API key. Read them from there every time; the base URL is usually `http://models.noodle.local/v1` and falls back to another port when port 80 is taken. One model is active at a time, so `serve` replaces the running one. The context is 4,096 tokens.

Done when `noodle model status --json` shows `"phase":"ready"` and a request with the key returns 200.

## 4. Call it

The endpoint speaks OpenAI Chat Completions (with streaming), OpenAI Responses at `/v1/responses` and Anthropic Messages at `/v1/messages`. The key works as a Bearer token or `x-api-key`. For any OpenAI client set `OPENAI_BASE_URL` and `OPENAI_API_KEY` from `endpoint`. Ollama's `/api/*` routes are not served.

| Endpoint | Model kind |
| --- | --- |
| `/v1/embeddings` | embedding, for example `qwen3-embedding-0.6b` |
| `/v1/audio/transcriptions` | speech to text, `qwen3-asr-0.6b` |
| `/v1/audio/speech` | text to speech, `kokoro-82m` |
| `/v1/images/generations`, `/v1/video/generations` | image and video models |

Treat the key as a secret: pass it through an environment variable and keep it out of files, logs and your reply. `noodle model key --rotate` replaces it and breaks every tool already configured, so rotate only when asked.

## From a container or pod

Access from workloads is opt-in. Find the bridge address, then serve on it:

```sh
gateway=$(docker --context noodle run --rm alpine:3.22 awk '$2 == "host.docker.internal" { print $1 }' /etc/hosts)
noodle model stop
noodle model serve qwen3.5-4b --workloads "$gateway"
noodle model endpoint
```

Use the printed workload URL inside the container. This path is plain HTTP on the VM network. `noodle model network on` opens the endpoint to the LAN; turn it on only when the user asks.

## Stop

`noodle model stop` ends the server. A served model also unloads after idle time and reloads on the next request (`noodle model keep-alive` shows or sets that time). `noodle model logs` explains a failed start. `noodle model rm ID` deletes a download; do it only for a model the user named.
