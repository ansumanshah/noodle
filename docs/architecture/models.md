# Local models

`noodle model` serves GGUF and MLX text models through one pinned
[mlx-serve](https://github.com/ddalcu/mlx-serve) process per Noodle home. GGUF files use its embedded
llama.cpp engine; MLX folders use its native engine. Both run on Apple silicon,
and model commands and the Models page work with the container daemon off.

```sh
noodle model run qwen3-0.6b-mlx
noodle model run qwen3.5-4b "Hello"
```

Catalog entries and their pinned revisions live in
`Sources/noodle/Commands/Models/ModelCatalog.swift`. The first start of any model downloads the same 103 MB runtime
archive. Noodle verifies its pinned size and SHA-256, extracts the whole tree
atomically into `NOODLE_HOME/models/mlx-serve/<version>/` and runs it in place.
Bundled libraries load relative to the executable. No runtime is bundled with
Noodle or built locally, and no Python environment is installed. Failed downloads
report their URL. Interrupted stages and superseded runtimes are cleaned up;
retired Python environments and separate GGUF runtime folders are removed.
The archive's licenses and NOTICE remain beside the executable.

Type `/exit` to leave CLI chat. Add a prompt after the model ID for one reply.
The Models page streams replies; Cancel response cancels that request and
preserves its partial reply without stopping other clients.

## Model folder

Weights live in `NOODLE_HOME/models/weights` by default. To keep them elsewhere,
such as an external drive, pick a folder in Settings > Models or run:

```sh
noodle model location /Volumes/Drive/models   # install and look for models here
noodle model location                         # print the current folder
noodle model location --reset                 # back to the default
```

The choice is saved in `NOODLE_HOME/models/location.json` and shared by the CLI,
daemon and app. The folder must exist and be writable. Changing it moves nothing:
models already installed stay in the old folder and leave the list until you
switch back or import them again. Staging and partial downloads go in hidden
folders inside the chosen folder, so installs stay a rename on the same volume.
If the folder is missing, for example because its drive is unplugged, pulls and
imports fail with an error and Noodle never creates the folder, so weights never
land on the startup disk by mistake.

Use `noodle model catalog` to see the catalog, `noodle model pull qwen3-0.6b-mlx`
to download separately, or `noodle model serve qwen3-0.6b-mlx` to start only the API.
For another compatible text model, import a GGUF file or an MLX model folder:

```sh
noodle model import path/to/model.gguf my-gguf
noodle model import path/to/mlx-folder my-mlx
```

Public Hugging Face repositories with a single-file GGUF can be pulled directly:

```sh
noodle model pull hf.co/bartowski/Llama-3.2-1B-Instruct-GGUF:Q4_K_M --progress-json
noodle model run hf.co/bartowski/Llama-3.2-1B-Instruct-GGUF:Q4_K_M "Hello"
```

The form is `hf.co/<org>/<repo>[:<quant>]`. Quantization matching is case
insensitive and matches the whole token. Without a tag, Noodle prefers Q4_K_M,
then the smallest GGUF by byte size. Projection files and recognized
MTP, DFlash, EAGLE3 and DSpark draft sidecars are skipped. Repositories
without runnable GGUF weights, missing requested quantizations and split GGUF
shards are rejected with an error. Safetensors repositories still need a local
MLX import. These pulls do not authenticate to private or gated repositories.

Noodle reads the commit and each file's `lfs.sha256` from the
[Hub model metadata API](https://huggingface.co/docs/hub/api), downloads over HTTPS
at that commit, and verifies the SHA-256 before installation. The weights and
receipt become visible together through the existing atomic install path.
The receipt records the model ID, commit, filename, size and SHA-256 under
`models/weights/huggingface/<id-hash>/receipt.json`. `list`, `serve`, `run` and `rm`
accept the same `hf.co/` ID. Pulling an installed ID checks its saved checksum;
remove it first to select weights from a newer Hub revision.

Imports copy data into Noodle's store. MLX imports require a config and
Safetensors weights in a folder, plus a tokenizer (`tokenizer.json`,
`tokenizer.model`, or `vocab.json` with `merges.txt`, which Qwen3-ASR ships). A
`kokoro` pack needs no tokenizer but must have `model.safetensors` and
`voices.safetensors`. The folder is flat except for one allowed subfolder,
`g2p/`, which may hold `.json` files (Kokoro's phoneme tables). Other
subfolders, symlinks (files or folders), escaping shard references and
executable Python files are not imported. Architecture support still depends
on the selected upstream runtime; an accepted folder is not a promise that every
Hugging Face architecture can run. Noodle does not enable remote model code.

`noodle model pull qwen3-0.6b-mlx --progress-json` emits one JSON object per line
with `phase`, `receivedBytes`, and `totalBytes`. The phases are `downloading`,
`verifying`, and `installed`. MLX progress aggregates all files. Installation is
atomic and completes only after every checksum passes. An interrupted download
starts again on retry; durable pause/resume is not implemented.

The base URL is `http://models.noodle.local/v1` while the daemon routes names (see below). `noodle model endpoint` prints it; the direct `http://127.0.0.1:11345/v1` is the fallback when names are off (`NOODLE_LOCAL_NAMES=0`) or the route is unavailable. Use the model name and API
key from `noodle model endpoint --json` in your client. CLI and store IDs retain
the `hf.co/` prefix; the runtime's request name for those entries is
`<org>/<repo>:<QUANT>`, which `endpoint` reports. Local import and catalog IDs
are unchanged.

`serve <id>` preloads that model and makes it the selected/default model. Serving
another installed model reuses the process, port and key. The runtime keeps an
LRU resident set, with its default limit of three models and automatic memory
admission. Inactive models can be evicted to fit another model. Requests name
their model explicitly, and an evicted model loads again when requested.

## Runtime launch

The private discovery view points at Noodle's weights; it never copies them.
MLX entries are directory links. GGUF entries are directories containing a
`model.gguf` link. Hub entries use a separate root so an organization name cannot
collide with a local model name. Both roots are supplied to the same process:

```sh
mlx-serve --model-dir <home>/models/mlx-home/models \
  --model-dir <home>/models/mlx-home/huggingface --serve --host <host> --port <port> \
  --api-key-env NOODLE_MODEL_API_KEY --api-key-strict \
  --prefix-cache-mem <RAM/32, 256 MB to 2 GB> --prefix-cache-disk 2GB \
  --llama-cache-entries 1 --ctx-size <4096 for GGUF, 32768 for MLX> --no-plugins --log-file off \
  [--idle-evict-secs <keep-alive seconds>]
```

The host is always explicit: `127.0.0.1`, or the validated VM bridge selected by
`--workloads`. `--api-key-strict` requires the session key from loopback too.
The key travels through the environment, never argv. The port, base URL and key
stay stable while models change. A different address or idle policy requires
stopping the shared process first.

`noodle model _exec` stays alive as the runtime's parent in the same process group, so
Stop still reaches both. If the runtime exits without a stop request it restarts after
1, 2, 4 ... 30 s and reloads the selected model; the fifth crash within ten minutes
gives up, and a runtime that exits before it ever answered is not restarted. `model status --json` reports `restarts` and `lastCrash` (the last ~20 log
lines). A request the engine refuses for GPU
memory (HTTP 400) reads "This Mac is short on memory right now" in `model run`;
`LocalModelMemoryRefusal` holds the detection.

The child gets `HOME=<home>/models/mlx-home`. Its SSD prefix cache lands in
`<home>/models/mlx-home/.mlx-serve/kv-cache`, and the user's `~/.mlx-serve`,
plugins and providers are untouched. `MLX_SERVE_*` overrides are cleared.
The MLX prefix cache gets RAM/32, clamped to 256 MB through 2 GB, plus a 2 GB
SSD tier for supported pure-attention models. GGUF uses the embedded engine's
sequence cache, limited to one entry to bound its per-model KV allocation.
Noodle passes `--ctx-size 4096` when the session starts with a GGUF model (upstream defaults to the model
maximum, 8192 for GGUF) and `--ctx-size 32768` when it starts with an MLX model, whose KV grows with use; coding
agents send 15,000 to 25,000 tokens before the first word. mlx-serve 26.11.2 ignores `--llama-cache-entries` for models it loads from
the model folders, so GGUF still reserves 4 sequences of that size; the flag only
takes effect for a model named with `--model` at startup. No KV quantization
override is passed. Resident memory and model admission use runtime defaults;
Noodle does not pass `--os-reserve-gib`. The runtime holds its power assertion while loading or
generating, so an idle process does not prevent Mac sleep.

Before preloading, Noodle refreshes the discovery links and calls
`POST /v1/models/rescan`, then `POST /v1/load-model` with `default: true`.
A failed preload preserves the previous session selection and key.
Pulls and imports also attempt a rescan when the process is already running.
An unavailable server does not undo an installed download; the next serve
refreshes discovery again.

## Idle eviction and stop

`run` and `serve` accept `--keep-alive`; `NOODLE_MODEL_KEEP_ALIVE` supplies the
value when the flag is absent. Below both sits a saved choice in
`models/keep-alive.json` (`noodle model keep-alive <duration> | --reset`, and
Settings > Models > Memory with 30 seconds, 5 minutes, 1 hour and Keep loaded).
Precedence is flag, then environment, then saved choice, then five minutes, for both formats.
`--idle-evict-secs` is a launch argument, so a saved change applies the next time
a model server starts; a running server keeps its value until `noodle model stop`
(the Unload Now button runs it). The saved choice never conflicts with a running
server, because only an explicit flag is compared against it:

```sh
noodle model serve qwen3.5-4b --keep-alive 1h
noodle model serve qwen3-0.6b-mlx --keep-alive -1
```

Durations follow Ollama's convention. Positive durations round up to whole
seconds; zero means one idle second; a negative duration omits the eviction
flag. The runtime tracks active requests and unloads unused models. Its server,
model listing, URL and key remain available, and the next request reloads the
model. The policy applies to the shared process rather than one format.

`noodle model stop` unloads the selected model through `/v1/unload-model`. If
other models remain loaded, the process and key stay live and status selects a
remaining model. If none remain loaded, Noodle stops the process and removes its
session and key. `status` describes the selected model; `list` describes weights
installed in the store. Removing the selected or another resident model is
refused until it has been stopped. For imports, `rm` deletes only Noodle's copy.

`noodle memory reclaim` stops the model the same way once the runner's log has been quiet for `--idle` seconds. The log is written by every request, so it stands in for the last request time that `noodle status --json` reports.

```sh
noodle model status
noodle model logs
noodle model stop
noodle model rm qwen3-0.6b-mlx
```

## Embedding and speech models

The catalog carries three models that are served as API only. They have a kind
(`chat`, `embeddings`, `speechToText`, `textToSpeech`), reported by
`LocalModel.kind`. Text to speech also plays in Models > Create (see Create below);
speech to text is used by chat to transcribe attached audio. The Models library shows them under the Embeddings and Speech
chips, and the chat picker, assistants and the first-run recommendation list
only chat models.

| ID | Pack (pinned commit in `ModelCatalog.swift`) | Size | License | Endpoint |
|---|---|---|---|---|
| `qwen3-embedding-0.6b` | `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ` | 0.34 GB | Apache-2.0 | `/v1/embeddings` |
| `qwen3-asr-0.6b` | `mlx-community/Qwen3-ASR-0.6B-4bit` | 0.71 GB | Apache-2.0 | `/v1/audio/transcriptions` |
| `kokoro-82m` | `ddalcu/Kokoro-82M-MLX-Serve` | 0.36 GB | Apache-2.0 | `/v1/audio/speech` |

mlx-serve recognises them by `config.json`: a `qwen3` embedding pack takes
last-token pooling from its folder name, so the ID keeps the word `embedding`;
`qwen3_asr` is the speech-to-text pack; `kokoro` is the speech pack. The
`mlx-community` Kokoro conversion is not used because it ships per-voice files
and no `model_type`, which mlx-serve does not load. The Kokoro entry is the
layout mlx-serve loads (`model.safetensors`, `voices.safetensors`, `g2p/`).

```sh
curl $BASE/embeddings -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"model":"qwen3-embedding-0.6b","input":"hello"}'
curl $BASE/audio/transcriptions -H "Authorization: Bearer $KEY" -F file=@speech.wav -F model=qwen3-asr-0.6b
curl $BASE/audio/speech -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"model":"kokoro-82m","input":"hello"}' -o speech.wav
```

The Connect page shows the matching sample for the running model. The Docker
Model Runner routes forward `embeddings` and `audio/speech` (JSON, 10 MB body
limit, same key rules). `audio/transcriptions` is not forwarded: it is multipart
and names its model in a form field, which the JSON guard cannot read, so it
answers 404 there. Use the native Models endpoint for transcription.

## Create

Models > Create sits beside Chat. It makes an image, a speech clip or a video from one prompt with an installed generation model. The kind switch lists only kinds with an installed model; with none, the page offers the catalog packs with their size and fit label. Generation models never appear in the chat picker.

| Kind | Catalog pack | Size | License | Endpoint |
|---|---|---|---|---|
| Image | `flux2-klein-4b` (Runpod/FLUX.2-klein-4B-mflux-4bit) | 4.6 GB | Apache-2.0 | `POST /v1/images/generations` |
| Speech | `kokoro-82m` | 0.36 GB | Apache-2.0 | `POST /v1/audio/speech` |
| Video | `ltx-2.5-video` (ddalcu/LTX-2.5-MLX-Serve-4bit) | 41.6 GB | LTX-2 Community License, not open source: paid license above 10 million USD yearly revenue | `POST /v1/video/generations` |

LTX needs 24 GB or more, so 16 GB Macs see it as too big. MiniMax-H3-Image (about 37 GB, 15.9 GB peak) and the H3 video packs do not fit 16 GB and are not in the catalog.

- Requests send `"stream": true`. The server answers with SSE: `progress` events (stage, step, total, and a base64 JPEG `preview` for video when the body asks for `preview: true`), `: keepalive` comments, then one `complete` or `error`. Image results are base64 PNG in `data[0].b64_json`, speech is a base64 WAV, video is raw `rgb8` frames plus optional `pcm_s16le` audio.
- The app muxes video frames and audio into H.264 and AAC `.mp4` with AVAssetWriter, off the main actor.
- Results live in `<home>/models/creations/` with an `index.json`, newest first. Each card has Save, Copy, Show in Finder and Delete. Speech plays inline.
- Before a job starts, a model whose size reads too big for this Mac is refused with a message. A server refusal (`"reason":"memory_refused"` from mlx-serve 26.11.3, or the older message text) shows the memory note instead of an error.
- If the runner is stopped or runs llama.cpp, Create starts mlx-serve with the chosen model; a running mlx-serve loads any installed model by name.
- Pack layout: the importer accepts the subfolders these packs use (`text_encoder`, `transformer`, `vae`, `tokenizer`, `gemma4-12b-ltx-v1`) with only weights, JSON and templates inside; symlinks are refused and code is skipped.

Measured on a 16 GB M4 with mlx-serve 26.11.3: a 1024 x 1024 FLUX.2 klein image at 4 steps took 64 s end to end including model load, peak runtime footprint 7.45 GB. A 3.45 s Kokoro clip took 0.8 s, peak footprint 2.3 GB.

## API shapes

The shared runtime serves these endpoints natively, under the same base URL and key:

- `/v1/chat/completions` (OpenAI Chat Completions)
- `/v1/responses` (OpenAI Responses)
- `/v1/messages` (Anthropic Messages)

mlx-serve accepts the key as a Bearer token or `x-api-key`. Noodle does not
translate between these API shapes.

```sh
curl http://models.noodle.local/v1/messages -H "Authorization: Bearer <key>" -H "anthropic-version: 2023-06-01" -H "Content-Type: application/json" \
  -d '{"model":"<id>","max_tokens":64,"messages":[{"role":"user","content":"hi"}]}'
```

The upstream runtime also exposes Ollama routes under `/api`. These routes have not passed Noodle acceptance; Noodle's own pull and import commands continue to own its model store.

## Models workspace

The desktop workspace has Chat, Library, Downloads and Connections tabs. Follow-up messages include completed exchanges from the current conversation. Cancelled or failed partial responses remain visible and are excluded from subsequent model context. New Chat starts a separate conversation. Local history is private and bounded to 30 nonempty conversations, 100 messages and 256 KiB of text per conversation. Invalid saved history is preserved and new messages stay in memory with a visible warning.

Downloads show byte progress and checksum verification. Cancel Download stops the owned request, waits for cleanup and refreshes the catalog. Retry restarts an interrupted transfer. Imports accept GGUF files or MLX folders; Remove deletes only Noodle's copy after confirmation.

Response metrics use a monotonic clock and server-reported token counts. `tok/s avg` includes the initial wait. It is not a GPU decode benchmark. No GPU-use reading is fabricated when the runtime does not provide one.

## Chat inputs

Chat takes images, one video and one audio clip per message (images: up to four). The attach button, paste and drag into the message box all accept them; a card-level drop target is avoided because it blanks offscreen renders, so drops go through the text view. Each kind is offered only when the running model reads it. The app asks `GET /v1/models` and reads `input_modalities` (`image`, `video`, `audio`) for the running row; `vision` in `capabilities` also counts as images. The `video` and `audio` entries in `capabilities` describe generation engines and are not used.

| Input | Reduction in the app | Wire shape |
|---|---|---|
| Image | long side at most 1024 px, JPEG | `image_url` part with a `data:image/jpeg;base64,` URL |
| Video | AVFoundation frames at about 1 per second, at most 32, long side 512 px, JPEG | `video_url` part: `{"frames": [data URLs], "fps": n}` |
| Audio | converted to 16 kHz mono 16-bit WAV, refused above 5 minutes (about 9.6 MB) | `input_audio` part: `{"data": base64, "format": "wav"}` |

mlx-serve has no video codec, so frame extraction is the client's job. A media-only message sends no empty text part, and a message with only attachments can be sent.

When the model cannot hear audio but a speech-to-text model (kind `speechToText`, for example `qwen3-asr-0.6b`) is installed, the app posts the WAV to the running server's `/v1/audio/transcriptions` with that model's ID, then sends the transcript as text after a `[Transcribed from <file name>]` note. Without either, the audio button is disabled and its tooltip says why. Recording from the microphone is not part of chat.

History keeps references only, under `<home>/models/chat-attachments/`: `<uuid>.jpg` for an image, `<uuid>.vid` for a video (JSON with the duration and the JPEG frames), `<uuid>.wav` for audio. Deleting a message or conversation removes files nothing else points at. Edit and resend, Regenerate and Retry after a model switch keep a message's attachments. A retried audio message is transcribed again, and its note then names the file generically because the original file name is not stored.

## Reaching Models from anywhere

Control-Option-Space opens the Models chat with the message box focused. It is a Carbon hot key, so it needs no Accessibility permission, and it works while the window is closed: the menu bar copy relaunches the full app on the chat page with `--focus-composer`. Settings > Appearance > Shortcut turns it off (default on, `quickAskHotKey` in user defaults). Registering the key adds no measurable memory.

App Intents appear in Shortcuts and Spotlight through `NoodleShortcuts`:

- Ask Noodle takes a text prompt, sends it to the running model's local endpoint and returns the answer as text. With no model running it starts the model picked in Models, and fails with a plain message when none is installed.
- Open Noodle Chat does what the hot key does.

## Use from other devices

Off by default. Settings > Models > Network, or `noodle model network on|off`, saves `models/network.json`. The server reads it at launch, so changing it restarts a running server (the command says so). With it on, the runtime binds `0.0.0.0` (the same port, and the VM bridge still works) and still runs `--api-key-env NOODLE_MODEL_API_KEY --api-key-strict`. Noodle does not use the runtime's `--lan-share` or Bonjour, which only work with no key.

The runtime's auth gate (`auth.zig`, `router.zig`) requires the key from every non-loopback peer on every route, including the index and metrics pages. Only `GET /health` and CORS preflight answer without it.

The key is one 64-character hex value, generated on first use and kept in `models/key` and `models/auth.header` (0600). It survives stop and restart. `noodle model key` prints it; `noodle model key --rotate` or "New Key" in Settings replaces it and restarts a running server, because the runtime reads the key at launch. Other devices use `http://<LocalHostName>.local:<port>/v1` (also shown as the Mac's IPv4 address) as an OpenAI base URL with the key as the API key. `noodle model endpoint` prints the network address when the setting is on. Traffic is plain HTTP on the local network.

## Named local API

When the same-home daemon is running, Models registers `models.noodle.local` for the live runner and verifies an authenticated request before exposing `namedBaseURL`. Native local-only A and AAAA records point to `127.0.0.1` and `::1`; no hosts-file or resolver edits are needed. IPv4 and IPv6 listeners use the same actual ports. A removed lease can be recreated by an explicit `model endpoint` call. Stop removes the owned lease. Polling status never starts the daemon or creates a route.

The packaged app may request macOS Local Network access before local-name registration is available. The direct local API remains available while that user permission is pending. Noodle supplies a purpose string and does not approve the system prompt automatically.

To keep Models on its direct address, create an empty `models/direct-connection` file inside the Noodle home (`~/.noodle` by default). This home-scoped choice applies to the app and CLI, skips named-route registration and cached-name probes, and releases any lease owned by the model on the next endpoint request. It does not stop the model or change container names. `NOODLE_LOCAL_NAMES=0` also disables model name registration for a command. Remove the marker to permit registration again.

Ports 80 and 443 are preferred. If another app holds them, use the actual fallback port printed in the app, for example `http://models.noodle.local:10080/v1`. The direct `baseURL` remains available and old JSON remains compatible. `.localhost` routes continue to work. A separate authority constrained to `noodle.local` issues branded HTTPS certificates; `noodle names ca noodle.local` prints it and `noodle names trust noodle.local` requests user trust. No certificate is trusted automatically. An explicit bridge-only binding keeps the direct workload URL.

The real resolver, authenticated HTTP/SSE and scoped TLS fixture check is `python3 tests/local-domains.py`. It creates and removes its own temporary home and starts no VM.

## Docker Compose and k3s

Opt in to guest access by serving on the Mac address assigned to the VM's NAT
bridge. Keep a container or the managed k3s cluster running while you set up
the listener so the bridge stays active. Find its address from a Noodle
container with networking enabled.

```sh
gateway=$(docker --context noodle run --rm alpine:3.22 awk '$2 == "host.docker.internal" { print $1 }' /etc/hosts)
noodle model stop
noodle model serve qwen3-0.6b-mlx --workloads "$gateway"
noodle model endpoint
```

The shared runtime binds the selected bridge address only; use the printed base
URL on the Mac too. It never binds all host interfaces. The API key is the persistent one in
`models/key`; loading another model preserves it.
For a Compose service use the printed workload endpoint, or
`OPENAI_BASE_URL=http://host.docker.internal:11345/v1`, and supply the key as
`OPENAI_API_KEY`. For a k3s pod, use the printed workload base URL and supply the
key from a Kubernetes Secret. The pod needs a route to the selected bridge.

Use the bridge listener with trusted local workloads. It uses HTTP on the VM
network, so credentials and prompts travel in cleartext on that network.
Inference requires the key. Health checks and read-only metadata remain
available according to the selected upstream server's API.

## Upstream files

- mlx-serve `26.11.4` is MIT licensed, with Apache-2.0 Metal kernels and jinja.cpp
  inside; its `LICENSE-APACHE-2.0` and `NOTICE` ship in the archive. The pin (URL,
  98,362,127 bytes, SHA-256 `2079e864…1e0832`) is in `Sources/NoodleCore/MLXServeRuntime.swift`.
  Inkling 2 Mini (`inkling2_loop`) needs this release or later.
  [Release](https://github.com/ddalcu/mlx-serve/releases/tag/v26.11.4)
- The MLX entry is `mlx-community/Qwen3-0.6B-4bit`, revision
  `73e3e38d981303bc594367cd910ea6eb48349da8`, licensed Apache-2.0.
  [Pinned model](https://huggingface.co/mlx-community/Qwen3-0.6B-4bit/tree/73e3e38d981303bc594367cd910ea6eb48349da8)
- The embedded GGUF engine is llama.cpp, MIT licensed, supplied by the same
  mlx-serve release. Noodle downloads no separate GGUF executable.
- The GGUF catalog entry uses Google's quantization-aware trained Gemma 4 E2B
  Q4_0 weights, licensed Apache-2.0. [Pinned weights](https://huggingface.co/google/gemma-4-E2B-it-qat-q4_0-gguf/blob/347eef722ec7f151f37d1ef0b5c7c77d8de4efcb/gemma-4-E2B_q4_0-it.gguf)

## Verification

The previous vLLM Metal runtime passed model download and hash checks,
authenticated chat/SSE, rejection without a key, four concurrent requests,
JSON-schema output, a forced tool call and `/v1/responses` on an M4 with 16 GiB.
Those probes still need a run against the pinned mlx-serve binary. The catalog
embedding model is checked separately (see Embedding and speech models).

`MLXServeRealBinaryTests` runs the pinned binary on real weights. It installs the
archive through the same verify-and-extract path as the first-use download, discovers
`qwen3-0.6b-mlx` and a supplied GGUF with Noodle's launch arguments and asserts a 401 from localhost
without the key, a streamed chat 200, `/v1/messages` with `x-api-key`, a larger
`cached_tokens` and a faster second response for a repeated long prompt, and
kv-cache files under the Noodle home. It also preloads and prompts the GGUF,
unloads it, and reloads MLX on the same process and key. It is skipped unless `NOODLE_MLX_REAL=1`; the
variables are listed at the top of the test file. Run it outside any sandbox:

```sh
NOODLE_MLX_REAL=1 NOODLE_MLX_HOME=/path/to/scratch/mlx-real \
NOODLE_MLX_ARCHIVE=/path/to/mlx-serve-bin-macos-arm64.tar.gz \
NOODLE_MLX_GGUF=/absolute/path/to/existing-text-model.gguf \
swift test --filter MLXServeRealBinaryTests
```

A real Docker CLI container can also check authenticated MLX inference and
rejection without a key on the selected private VM bridge. The probe image contains
only the repository-built static client; its disposable key travels through stdin.
Run it with `just test-models-mlx-workloads`.
It downloads the pinned model and runtime on first use, then removes its own VM/home.
This does not replace a Compose or k3s pod acceptance test for MLX.

Pin 26.11.4 verification (archive 98,362,127 bytes, SHA-256 `2079e8649b4a25aed267bf43117ef23b026c833453f0cdd0eff2d328aa1e0832`, matching `MLXServeRuntime.pin`; GGUF check used a Qwen 3 0.6B Q4_K_M file): `MLXServeRealBinaryTests` passed and the `model-workloads` e2e file passed. `bonsai2-27b` on a 16 GB M4: refused by the memory check with normal apps open (needs about 10.0 GB free, 7.2 GB available); with the check skipped it answered at 17.5 tokens per second, footprint 8.3 GB, peak 9.5 GB, and the Mac swapped 4.6 GB. The Inkling packs were not loaded: on a 16 GB M4 the 2.5-bit Inkling 2 Mini pack was refused before load (needs about 12.4 GB free, 6.3 GB available).

Pin 26.11.3 verification (archive 103,345,925 bytes, SHA-256 `a45db31a0a670dc551ed2f220719dc991a2ca13aaae9ec7d2a857625da7f32e4`, matching `MLXServeRuntime.pin`; GGUF check used the Gemma 4 E2B Q4_0 file): `MLXServeRealBinaryTests` passed; `just test-models-mlx-workloads` passed (bridge inference 200, missing key 401); the `model-workloads` e2e file passed; `model-runner-cli` passed with `E2E_MODEL_RUNNER_INTEGRATED=1`. `model-runner-compose-models` failed at its keyless probe (`wget: error getting response: Invalid argument`), the same failure seen on 26.11.2, so it is not a pin regression. One real request per catalog pack on 26.11.3: `qwen3.5-2b` chat, `qwen3.5-4b` chat with an image (`/v1/models` lists `vision`), `qwen3-embedding-0.6b` (1024 dimensions), `qwen3-asr-0.6b` (exact transcript of a 16 kHz WAV), `kokoro-82m` (24 kHz WAV) and `flux2-klein-4b` (512 x 512 PNG, 4 steps).

Offline model-store checks use synthetic weights and never load them:

```sh
NOODLE_BIN="$(swift build --show-bin-path)/noodle" bash tests/models-imports.sh
```

`swift test --filter 'MLX|Model|KeepAlive'` covers keep-alive parsing, shared idle eviction
rounding, direct exec arguments/PID, the MLX pin, verify and atomic install, its
launch arguments and environment, and Hugging Face
metadata and quantization fixtures. It downloads no model weights. Loopback fixtures cover CLI precedence,
stop and HF store integration, and are skipped when listening sockets are denied.
These fixtures do not establish real GGUF/MLX inference or live Hub download acceptance.

The fixture executable is resolved beside the active test bundle, including
release builds and custom scratch paths. `NOODLE_BIN` can select an explicit
executable instead.

`NOODLE_BIN="$(swift build --show-bin-path)/noodle" bash tests/models.sh` uses
a fresh home, fetches the pinned Gemma weights and shared runtime, streams a response, and
checks that stop releases the listener. Build the CLI first. For repeat runs,
`NOODLE_MODELS_GGUF` may point to a copy of the pinned Gemma file; its hash is
still verified. `just e2e model-workloads` checks the same endpoint from a real
Compose service and managed k3s pod, including rejection without a key.

## Docker Model Runner compatibility

The daemon serves Docker Model Runner routes on its Unix socket and an authenticated model-only HTTP facade. Noodle installs Docker's upstream v1.2.9 plugin through the existing pinned lazy-tools path. Its managed stub follows the active Docker context and sets upstream's standard host/proxy variables. Explicit runner settings and foreign plugins are preserved.

Compose `models:` receives a URL containing a private capability and the model name through Docker's own plugin. Containers call that URL at `host.docker.internal`; no separate key variable is needed. The facade binds Mac loopback and explicit VM bridge addresses, claims its port so the Mac loopback relay cannot reach it, and restricts guest callers to inference and read-only metadata. The strict-key backend remains private.

The adapter targets the single `mlx-serve` process, including multiple loaded models on the same port. It uses existing CLI lifecycle commands and authenticated load records. Catalog IDs, public HF references and restricted single-file Hub GGUF artifacts share Noodle's store. Snapshot logs are supported; custom runtime settings and unsupported OCI layouts return explicit errors.

Contract and offline installer checks pass; real VM, live registry download and integrated native inference acceptance remain pending.
