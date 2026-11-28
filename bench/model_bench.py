#!/usr/bin/env python3
"""Sequential loopback OpenAI completions benchmark; starts no servers. See models-README.md."""
import argparse
from datetime import datetime, timezone
import hashlib
import ipaddress
import json
import math
import os
from pathlib import Path
import platform
import socket
import stat
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

VERSION = "1.0.0"
TEMPLATE = "<|im_start|>user\n{content}<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
TIMEOUT_SECONDS = 180
MAX_STREAM_BYTES = 8 * 1024 * 1024


def percentile(values, fraction):
    if not values:
        return None
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    low = math.floor(position)
    high = min(low + 1, len(ordered) - 1)
    return ordered[low] + (ordered[high] - ordered[low]) * (position - low)


def endpoint(base_url):
    parsed = urllib.parse.urlsplit(base_url)
    if (parsed.scheme != "http" or not parsed.hostname or parsed.username is not None
            or parsed.password is not None or parsed.query or parsed.fragment):
        raise ValueError("--base-url must be a loopback HTTP URL without credentials, query or fragment")
    host = parsed.hostname
    if host == "localhost":
        addresses = socket.getaddrinfo(host, parsed.port or 80, type=socket.SOCK_STREAM)
        if not addresses or not all(ipaddress.ip_address(a[4][0]).is_loopback for a in addresses):
            raise ValueError("localhost must resolve only to loopback addresses")
    elif not ipaddress.ip_address(host).is_loopback:
        raise ValueError("--base-url must use a loopback address")
    path = parsed.path.rstrip("/") or "/v1"
    return urllib.parse.urlunsplit(("http", parsed.netloc, path + "/completions", "", ""))


def read_key(path):
    if path is None:
        return None
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "r", encoding="utf-8") as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077 or info.st_uid != os.geteuid():
            raise ValueError("--key-file must be a private regular file owned by the current user (mode 600 or 400)")
        key = source.read(16385).strip()
    if not key or len(key) > 16384 or "\r" in key or "\n" in key:
        raise ValueError("--key-file must contain one nonempty API key line")
    return key


def prompts(samples, warmups, seed):
    long_records = "\n".join(
        f"Record {i:02d}: Team {i % 8 + 1} packed {i * 3} boxes before noon and delivered {i * 2} boxes after lunch."
        for i in range(1, 33)
    )
    for workload in ("short", "long"):
        for phase, count in (("warmup", warmups), ("measured", samples)):
            for index in range(count):
                identity = f"{seed}:{workload}:{phase}:{index}"
                identifier = hashlib.sha256(identity.encode()).hexdigest()[:24]
                lead = f"Request identifier: {identifier}\n"
                if workload == "short":
                    content = lead + (
                        "Write one practical paragraph explaining how to keep a small workshop tidy. "
                        "Use about 100 words. Do not repeat the request identifier."
                    )
                else:
                    content = lead + long_records + (
                        "\nSummarize the workshop records in one paragraph of about 100 words. "
                        "Describe the pattern without adding facts or repeating the request identifier."
                    )
                yield {"workload": workload, "phase": phase, "index": index,
                       "identifier": identifier, "prompt": TEMPLATE.format(content=content)}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        return None


def run_sample(opener, url, key, body, sample):
    headers = {"Content-Type": "application/json", "Accept": "text/event-stream"}
    if key:
        headers["Authorization"] = "Bearer " + key
    request = urllib.request.Request(url, json.dumps(body).encode(), headers, method="POST")
    started = time.perf_counter()
    first_text = last_text = None
    raw_lines, events, output = [], [], []
    usage = None
    finished = False
    finish_reason = None
    total_bytes = 0

    def consume(lines, received):
        nonlocal first_text, last_text, usage, finished, finish_reason
        data_lines, event_type = [], "message"
        for line in lines:
            if line.startswith("data:"):
                data_lines.append(line[5:].removeprefix(" "))
            elif line.startswith("event:"):
                event_type = line[6:].strip()
        if not data_lines:
            return
        data = "\n".join(data_lines)
        events.append({"receivedMS": (received - started) * 1000, "event": event_type, "data": data})
        if data.strip() == "[DONE]":
            finished = True
            return
        chunk = json.loads(data)
        if not isinstance(chunk, dict):
            raise ValueError("SSE data is not a JSON object")
        if event_type == "error" or chunk.get("error") is not None:
            raise ValueError("upstream SSE error: " + json.dumps(chunk))
        if chunk.get("usage") is not None:
            usage = chunk["usage"]
        choices = chunk.get("choices", [])
        if not isinstance(choices, list):
            raise ValueError("invalid completions choices")
        for choice in choices:
            if choice.get("index", 0) != 0:
                raise ValueError("unexpected multiple completion choices")
            text = choice.get("text", "")
            if not isinstance(text, str):
                raise ValueError("completion text is not a string")
            if text != "":
                if first_text is None:
                    first_text = received
                last_text = received
                output.append(text)
            if choice.get("finish_reason") is not None:
                finish_reason = choice["finish_reason"]

    try:
        with opener.open(request, timeout=TIMEOUT_SECONDS) as response:
            sample["httpStatus"] = response.status
            sample["responseContentType"] = response.headers.get("Content-Type")
            if response.headers.get_content_type() != "text/event-stream":
                sample["rawResponse"] = response.read(MAX_STREAM_BYTES).decode("utf-8", errors="replace")
                raise ValueError("upstream response is not text/event-stream")
            pending = []
            while not finished:
                line = response.readline(MAX_STREAM_BYTES + 1)
                received = time.perf_counter()
                if not line:
                    raise ValueError("truncated SSE stream: missing [DONE]")
                total_bytes += len(line)
                if total_bytes > MAX_STREAM_BYTES:
                    raise ValueError("SSE response exceeded the 8 MiB safety limit")
                decoded = line.decode("utf-8")
                raw_lines.append(decoded)
                stripped = decoded.rstrip("\r\n")
                if stripped:
                    pending.append(stripped)
                else:
                    consume(pending, received)
                    pending = []
        if not isinstance(usage, dict):
            raise ValueError("completed stream did not include usage token counts")
        for field in ("prompt_tokens", "completion_tokens"):
            if type(usage.get(field)) is not int or usage[field] < 0:
                raise ValueError("invalid or missing usage." + field)
        if first_text is None or usage["completion_tokens"] < 1:
            raise ValueError("completed stream contains no generated text")
        if finish_reason is None:
            raise ValueError("completed stream is missing finish_reason")
        sample["status"] = "ok"
        return True
    except urllib.error.HTTPError as error:
        sample["httpStatus"] = error.code
        sample["rawResponse"] = error.read(MAX_STREAM_BYTES).decode("utf-8", errors="replace")
        sample["error"] = {"type": type(error).__name__, "message": str(error)}
        return False
    except (Exception, KeyboardInterrupt) as error:
        sample["error"] = {"type": type(error).__name__, "message": str(error)}
        return False
    finally:
        elapsed = time.perf_counter() - started
        tokens = usage.get("completion_tokens") if isinstance(usage, dict) else None
        decode_seconds = last_text - first_text if first_text is not None else None
        sample.update({
            "status": "ok" if sample.get("status") == "ok" else "error",
            "rawSSE": "".join(raw_lines), "events": events,
            "output": "".join(output), "usage": usage, "finishReason": finish_reason,
            "doneReceived": finished, "totalLatencyMS": elapsed * 1000,
            "ttftMS": (first_text - started) * 1000 if first_text is not None else None,
            "lastTextMS": (last_text - started) * 1000 if last_text is not None else None,
            "decodeTokensPerSecond": ((tokens - 1) / decode_seconds
                                       if type(tokens) is int and tokens > 1 and decode_seconds else None),
        })


def summarize(samples):
    result = {}
    for workload in ("short", "long"):
        measured = [s for s in samples if s["workload"] == workload and s["phase"] == "measured"]
        valid = [s for s in measured if s["status"] == "ok"]
        row = {"completed": len(valid), "failed": sum(s["status"] == "error" for s in measured)}
        for metric in ("ttftMS", "totalLatencyMS", "decodeTokensPerSecond"):
            values = [s[metric] for s in valid if s.get(metric) is not None]
            row[metric] = {"n": len(values), "p50": percentile(values, .5), "p95": percentile(values, .95)}
        row["promptTokens"] = [s["usage"]["prompt_tokens"] for s in valid]
        row["outputTokens"] = [s["usage"]["completion_tokens"] for s in valid]
        result[workload] = row
    return result


def save(path, report, key):
    report["summary"] = summarize(report["samples"])

    def redact(value):
        if isinstance(value, str):
            return value.replace(key, "[REDACTED]") if key else value
        if isinstance(value, list):
            return [redact(item) for item in value]
        if isinstance(value, dict):
            return {redact(name): redact(item) for name, item in value.items()}
        return value

    serialized = json.dumps(redact(report), indent=2, allow_nan=False)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile("w", dir=path.parent, prefix=path.name + ".", delete=False) as target:
            temporary = Path(target.name)
            target.write(serialized + "\n")
        temporary.replace(path)
    finally:
        if temporary and temporary.exists():
            temporary.unlink()


def positive(value):
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be positive")
    return number


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", required=True, help="loopback OpenAI base URL, e.g. http://127.0.0.1:11434/v1")
    parser.add_argument("--model", required=True, help="public model name served by this engine")
    parser.add_argument("--label", required=True, help="engine/run label")
    parser.add_argument("--output", required=True, type=Path, help="raw JSON evidence file")
    parser.add_argument("--key-file", type=Path, help="private file containing the API key; key is never recorded")
    parser.add_argument("--samples", type=positive, default=30, help="measured requests per prompt class (default: 30)")
    parser.add_argument("--warmups", type=int, default=5, help="unmeasured requests per prompt class (default: 5)")
    parser.add_argument("--max-tokens", type=positive, default=128)
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--metadata", type=Path, help="JSON with hardware, model revision, quantization, and server settings")
    args = parser.parse_args()
    if args.warmups < 0:
        parser.error("--warmups must be nonnegative")
    plan = list(prompts(args.samples, args.warmups, args.seed))
    settings = {"temperature": 0, "top_p": 1, "stream": True,
                "stream_options": {"include_usage": True}, "max_tokens": args.max_tokens,
                "seed": args.seed, "stop": ["<|im_end|>", "<|endoftext|>"]}
    report = {"schemaVersion": 1, "harnessVersion": VERSION, "label": args.label, "model": args.model,
              "startedAt": datetime.now(timezone.utc).isoformat(), "status": "running",
              "host": {"system": platform.system(), "release": platform.release(), "machine": platform.machine()},
              "python": platform.python_version(), "settings": settings,
              "template": TEMPLATE, "promptClassOrder": ["short", "long"],
              "samplesPerClass": args.samples, "warmupsPerClass": args.warmups,
              "promptSetSHA256": hashlib.sha256(json.dumps(plan, sort_keys=True).encode()).hexdigest(),
              "samples": []}
    key = None
    try:
        key = read_key(args.key_file)
        report["endpoint"] = url = endpoint(args.base_url)
        report["metadata"] = json.loads(args.metadata.read_text()) if args.metadata else {}
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        save(args.output, report, key)
        for prompt in plan:
            body = {"model": args.model, "prompt": prompt["prompt"], **settings}
            sample = {**prompt, "requestBody": body, "status": "running"}
            report["samples"].append(sample)
            save(args.output, report, key)
            succeeded = run_sample(opener, url, key, body, sample)
            if not succeeded:
                report["status"] = "error"
                save(args.output, report, key)
                print("Benchmark stopped after a failed sample; partial JSON saved.", file=sys.stderr)
                return 1
            save(args.output, report, key)
            print(f"{args.label} {sample['workload']} {sample['phase']} {sample['index'] + 1}: "
                  f"TTFT {sample['ttftMS']:.1f} ms", flush=True)
        report["status"] = "complete"
        report["finishedAt"] = datetime.now(timezone.utc).isoformat()
        save(args.output, report, key)
        print(f"Saved {args.output}")
        return 0
    except (Exception, KeyboardInterrupt) as error:
        report["status"] = "error"
        report["error"] = {"type": type(error).__name__, "message": str(error)}
        save(args.output, report, key)
        print("Benchmark failed; partial JSON saved.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
