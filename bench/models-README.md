# Local model benchmark

`model_bench.py` measures an already-running OpenAI-compatible server on loopback HTTP. It uses only Python's standard library. It does not start an engine, install a runtime, or download a model.

Run one engine at a time on the same Mac, on AC power, with other heavy work stopped. Keep the same context limit, sampling settings, harness version, and workload counts. Use a 4,096-token server context. The harness defaults to 128 generated tokens at most, five warmups per prompt class, and 30 measured requests per class. Configure the context limit when starting each server; the harness does not change it.

```sh
python3 bench/model_bench.py \
  --base-url http://127.0.0.1:11550/v1 \
  --model qwen3-bench --label noodle-gguf \
  --key-file build/model-bench/noodle-home/models/key \
  --metadata build/model-bench/noodle-gguf-metadata.json \
  --output build/model-bench/noodle-gguf.json

# Stop Noodle's model server before starting the selected Ollama model server.
python3 bench/model_bench.py \
  --base-url http://127.0.0.1:11434/v1 \
  --model qwen3-bench --label ollama-gguf \
  --metadata build/model-bench/ollama-gguf-metadata.json \
  --output build/model-bench/ollama-gguf.json
```

Use a private, current-user-owned regular file with mode `600` or `400` for `--key-file`. The key is read from that file and sent in the Authorization header. It is excluded from the report and never passed as a command-line argument. Proxy environment variables are ignored, and redirects are refused. The base URL must be HTTP on a loopback IP address or `localhost` resolving only to loopback addresses.

To repeat the comparison, import the same GGUF (the Modelfile below names it) into both products as `qwen3-bench`; do not substitute an Ollama library tag. Check the imported copy/blob digest too. Noodle uses an isolated `NOODLE_HOME` and `model serve qwen3-bench --port 11550`.

Ollama 0.40.16's `/v1/completions` applies a chat template unless configured otherwise. The benchmark import uses this Modelfile, with the actual absolute file path:

```text
FROM /absolute/path/Qwen3-0.6B-Q4_K_M.gguf
TEMPLATE """{{ .Prompt }}"""
PARAMETER num_ctx 4096
PARAMETER repeat_penalty 1.0
```

Start only the benchmark's server with `OLLAMA_GO_TEMPLATE=1`, `OLLAMA_NUM_PARALLEL=1`, `OLLAMA_MAX_LOADED_MODELS=1`, `OLLAMA_CONTEXT_LENGTH=4096`, `OLLAMA_FLASH_ATTENTION=1`, `OLLAMA_KV_CACHE_TYPE=f16`, `OLLAMA_NO_CLOUD=1`, `OLLAMA_KEEP_ALIVE=-1`, and `LLAMA_ARG_CACHE_RAM=128`. Set `OLLAMA_HOST` to its dedicated loopback port and `OLLAMA_MODELS` to the benchmark directory. Use the same host for `ollama create`. These are the tested pinned-version settings; the `LLAMA_ARG_CACHE_RAM` variable is inherited by its bundled llama.cpp runner. Noodle passes its 128 MiB limit explicitly.

Verify the native `/api/generate` diagnostic with `"_debug_render_only": true` before timing. Its `_debug_info.rendered_template` must exactly match the harness prompt. The OpenAI diagnostic response omits that field. Then compare actual per-request `usage.prompt_tokens` as a second check. The recorded pair also has identical completion token counts and output. A model name alone does not prove matching work.

The normal Ollama command-line server creates `~/.ollama/id_ed25519` and its public key on first startup even with a separate model directory. Preserve existing files. The recorded orchestration removed only its own newly created, unchanged keys after stopping its owned process group; it did not change `HOME`, shell configuration or installed apps.

The metadata JSON should record the Mac model, chip, RAM, macOS version, power mode, engine and runtime versions, exact model revision or digest, weight format, quantization, context limit, cache settings, and server launch settings. Record the run order and any background load. Leave LM Studio out of a comparison when it is absent; do not infer its performance from another engine.

## Prompts and requests

The short prompt asks for a paragraph about workshop organization. The long prompt includes 32 synthetic workshop records and asks for a summary. Its target is roughly 1,000 input tokens; each server's reported `usage.prompt_tokens` gives the actual count. Both fit the intended 4,096-token context with the default output limit.

Every warmup and measured prompt starts with a unique identifier immediately after the fixed user-role marker. Identifiers derive from the seed, prompt class, phase, and sample index. Engines receive identical prompt strings when those settings match. This limits reusable prompt prefixes, although the role marker and part of the identifier label remain shared. It does not disable server caching.

Requests use `/v1/completions` with the raw [Qwen3 tokenizer template](https://huggingface.co/Qwen/Qwen3-0.6B/blob/main/tokenizer_config.json), no system message, and this exact nonthinking assistant prefill:

```text
<|im_start|>user
{content}<|im_end|>
<|im_start|>assistant
<think>

</think>

```

The Python constant and every raw request body are saved in the report, including the exact trailing newlines. Completions avoid differences between backend chat-template rendering. The request uses `temperature: 0`, `top_p: 1`, `seed: 7`, streaming with usage, and stops at `<|im_end|>` or `<|endoftext|>`. A seed is a requested setting, not a guarantee of equal generated text across runtimes.

The run sends all short warmups, then short measurements, followed by long warmups and measurements. Requests are sequential with a new HTTP connection for each. Model load time is outside the intended measurement; confirm each model is loaded before running the harness. Warmups remain in the raw evidence but are excluded from summaries.

## Measurements and evidence

- **TTFT:** client request start to the first nonempty completion text delta. Whitespace counts as text; empty chunks do not.
- **Total latency:** client request start through the completed SSE stream and usage validation. It includes HTTP setup and client parsing.
- **Client decode tokens/s:** `(completion_tokens - 1) / (last_text_time - first_text_time)`. A single text chunk or fewer than two output tokens yields `null`. This is a client streaming proxy. Chunks can contain multiple tokens, and server token counts can include tokens that do not appear as text.
- **Token counts:** the server's prompt and completion usage, retained for every sample. Output lengths can differ despite matching sampling settings.
- **p50 and p95:** sorted samples with linear interpolation at `(n - 1) × percentile`. Only successful measured samples enter these summaries. Each metric reports its sample count.

Each JSON file retains prompts, request settings, raw SSE, event arrival times, generated text, usage, finish reason, and per-sample errors. It also includes a prompt-set SHA-256 for checking that both runs used the same workload. The report is atomically checkpointed before and after each sample. HTTP errors, SSE errors, malformed events, missing usage, and a stream ending without `[DONE]` stop the run with a nonzero exit and a partial report. A single request has a 180-second socket timeout; a response is limited to 8 MiB.

Inspect generated text and finish reasons before publishing. `finish_reason: length` means the output reached the requested cap. A complete benchmark report does not establish answer quality. Publish raw JSON with any chart and retain failures. For website evidence, repeat runs in alternating engine order and report the machine, model formats, sample counts, and limitations alongside the numbers.

MLX 4-bit and GGUF `Q4_K_M` use different weight representations and quantization schemes. Matching the source model and parameter count does not make their weights numerically equal. Describe this as a comparison of these local serving configurations. Do not claim equal-weight inference, backend-only speed differences, or a general winner from these runs.
