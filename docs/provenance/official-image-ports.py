#!/usr/bin/env python3
"""Collect the ports declared by the most-pulled Docker Official Images.

Output: official-image-ports.json next to this script. A second tool,
gen-official-image-ports.py, turns that JSON (and nothing else) into Swift.

Method
  1. List the library namespace on Docker Hub ordered by pull count, newest
     counts first, and keep the first TOP_N repositories.
  2. For each, take an anonymous pull token from the registry auth service,
     fetch the manifest (an index is resolved to its linux/arm64 entry, or
     linux/amd64 when there is no arm64), then the image config blob, and read
     config.ExposedPorts.
  3. "count" in the output is per port: the number of the TOP_N images whose
     config exposes that port (each image counted once per port, tcp and udp
     merged). The top-level "portCounts" holds the same numbers.
  4. Class of an image. Preferred signal: the Hub category slugs. An image is
     not-web when any of its slugs is in NOT_WEB_CATEGORIES. When Hub lists no
     category, a name rule applies: names containing a NOT_WEB_NAME_HINTS word
     (database, cache, search engine, broker, coordination store) are not-web,
     all other images are web.
  5. Class of a port: web when at least one web image exposes it, otherwise
     not-web. Ports are ranked by descending count, ties by ascending port.

Only anonymous, public endpoints are used. Standard library only.
"""
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import date
from pathlib import Path

TOP_N = 100
HUB = "https://hub.docker.com/v2/repositories/library/"
AUTH = "https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/{repo}:pull"
REGISTRY = "https://registry-1.docker.io/v2/library/{repo}/{kind}/{ref}"
UA = "official-image-ports/1.0 (public API reader)"
NOT_WEB_CATEGORIES = {"databases-and-storage", "message-queues"}
NOT_WEB_NAME_HINTS = (
    "sql", "db", "redis", "memcache", "mongo", "cassandra", "couch", "elastic",
    "solr", "rabbit", "mosquitto", "nats", "kafka", "zookeeper", "etcd", "neo4j",
    "influx", "consul", "arango", "rethink",
)
MANIFEST_TYPES = ", ".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
])


def get(url, headers=None, tries=4):
    req = urllib.request.Request(url, headers={"User-Agent": UA, **(headers or {})})
    for attempt in range(tries):
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code in (429, 500, 502, 503) and attempt < tries - 1:
                time.sleep(2 ** attempt)
                continue
            raise
        except urllib.error.URLError:
            if attempt < tries - 1:
                time.sleep(2 ** attempt)
                continue
            raise


def top_repositories():
    out, url = [], HUB + "?" + urllib.parse.urlencode({"page_size": 100, "ordering": "pull_count"})
    while url and len(out) < TOP_N:
        page = get(url)
        out += page["results"]
        url = page.get("next")
    return out[:TOP_N]


def exposed_ports(repo):
    token = get(AUTH.format(repo=repo))["token"]
    auth = {"Authorization": "Bearer " + token, "Accept": MANIFEST_TYPES}
    m = get(REGISTRY.format(repo=repo, kind="manifests", ref="latest"), auth)
    if "manifests" in m:
        entries = [e for e in m["manifests"] if e.get("platform", {}).get("os") == "linux"]
        pick = next((e for e in entries if e["platform"].get("architecture") == "arm64"), None) \
            or next((e for e in entries if e["platform"].get("architecture") == "amd64"), None)
        if pick is None:
            raise RuntimeError("no linux/arm64 or amd64 entry")
        m = get(REGISTRY.format(repo=repo, kind="manifests", ref=pick["digest"]), auth)
    cfg = get(REGISTRY.format(repo=repo, kind="blobs", ref=m["config"]["digest"]), auth)
    keys = (cfg.get("config") or {}).get("ExposedPorts") or {}
    return sorted({int(k.split("/")[0]) for k in keys})


def image_is_web(name, slugs):
    if slugs:
        return not (set(slugs) & NOT_WEB_CATEGORIES)
    return not any(h in name for h in NOT_WEB_NAME_HINTS)


def main():
    repos = top_repositories()
    records, counts = [], {}
    for r in repos:
        name = r["name"]
        slugs = [c["slug"] for c in r.get("categories") or []]
        rec = {"image": name, "category": slugs, "web": image_is_web(name, slugs), "pulls": r["pull_count"]}
        try:
            rec["ports"] = exposed_ports(name)
        except Exception as e:  # keep going; the failure is recorded
            rec["ports"], rec["error"] = [], str(e)
            print(f"{name}: {e}", file=sys.stderr)
        for p in rec["ports"]:
            counts[p] = counts.get(p, 0) + 1
        records.append(rec)
    web_ports = {p for rec in records if rec["web"] for p in rec["ports"]}
    for rec in records:
        rec["count"] = {str(p): counts[p] for p in rec["ports"]}
    doc = {
        "retrieved": date.today().isoformat(),
        "endpoints": [HUB, AUTH, REGISTRY],
        "topN": TOP_N,
        "countMeaning": "per-port: number of listed images exposing that port",
        "notWebCategories": sorted(NOT_WEB_CATEGORIES),
        "notWebNameHints": list(NOT_WEB_NAME_HINTS),
        "portCounts": {str(p): counts[p] for p in sorted(counts)},
        "portClass": {str(p): ("web" if p in web_ports else "notweb") for p in sorted(counts)},
        "images": records,
    }
    out = Path(__file__).with_name("official-image-ports.json")
    out.write_text(json.dumps(doc, indent=1) + "\n")
    print(f"wrote {out} ({len(records)} images, {len(counts)} ports)")


if __name__ == "__main__":
    main()
