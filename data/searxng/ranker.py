"""SearXNG per-engine proxy ranker.

Continuously probes each (upstream-engine × exit-node-HTTP-proxy) pair,
maintains EWMA success-rate + latency, and rewrites the searxng ConfigMap
with ranked proxy lists per engine. Triggers a rolling restart of the
searxng Deployment after each successful cycle so the new settings.yml
takes effect.
"""

from __future__ import annotations

import dataclasses
import logging
import os
import random
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any, Callable

import httpx
import yaml
from kubernetes import client, config

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    stream=sys.stdout,
)
# httpx + httpcore log every single request at INFO; drown the actual
# per-cycle ranking summary. Raise them to WARNING.
logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("httpcore").setLevel(logging.WARNING)
log: logging.Logger = logging.getLogger("searxng-ranker")


# ---------- configuration ----------

NAMESPACE = os.environ.get("SEARXNG_NAMESPACE", "searxng")
CONFIGMAP = os.environ.get("SEARXNG_CONFIGMAP", "searxng-config")

INTERVAL = int(os.environ.get("RANKER_INTERVAL_SECONDS", "43200"))
PROBE_TIMEOUT = float(os.environ.get("RANKER_PROBE_TIMEOUT_SECONDS", "8"))
TOP_N = int(os.environ.get("RANKER_TOP_N", "8"))
ALPHA = float(os.environ.get("RANKER_EWMA_ALPHA", "0.3"))
HEALTH_PORT = int(os.environ.get("RANKER_HEALTH_PORT", "8090"))

# Proxies are supplied space-separated via env (rendered from local.exitnode_names).
PROXIES: list[str] = [p for p in os.environ.get("EXITNODE_PROXIES", "").split() if p]


# ---------- engine probe specs ----------


def _validator_html(*needles: str) -> Callable[[str], bool]:
    def check(body: str) -> bool:
        return any(n in body for n in needles)
    return check


def _validator_google(body: str) -> bool:
    if "detected unusual traffic" in body.lower():
        return False
    if "sorry/index" in body.lower():
        return False
    return "<title>" in body and ("google" in body.lower())


def _validator_wikipedia_json(body: str) -> bool:
    import json
    try:
        data = json.loads(body)
        return isinstance(data, list) and len(data) >= 2
    except Exception:
        return False


def _validator_qwant_json(body: str) -> bool:
    import json
    try:
        data = json.loads(body)
        return "data" in data and "result" in data.get("data", {})
    except Exception:
        return False


@dataclasses.dataclass(frozen=True)
class ProbeSpec:
    name: str
    url: str
    validator: Callable[[str], bool]


# httpx.Client(proxy=...) leaks ~1MB/probe even under `with`; reuse one per proxy
# for the process lifetime so we stay inside the 512Mi limit across cycles.
_CLIENTS: dict[str, httpx.Client] = {}


def _client_for(proxy_url: str) -> httpx.Client:
    c = _CLIENTS.get(proxy_url)
    if c is None:
        c = httpx.Client(proxy=proxy_url, timeout=PROBE_TIMEOUT, follow_redirects=True)
        _CLIENTS[proxy_url] = c
    return c


ENGINES: list[ProbeSpec] = [
    ProbeSpec("google",
              "https://www.google.com/search?q=test",
              _validator_google),
    ProbeSpec("brave",
              "https://search.brave.com/search?q=test",
              _validator_html("search-result", "snippet-title")),
    ProbeSpec("duckduckgo",
              "https://html.duckduckgo.com/html?q=test",
              _validator_html("result__", "results_links")),
    ProbeSpec("startpage",
              "https://www.startpage.com/sp/search?query=test",
              _validator_html("w-gl__result", "result")),
    ProbeSpec("mojeek",
              "https://www.mojeek.com/search?q=test",
              _validator_html("result", "results-standard")),
    ProbeSpec("bing",
              "https://www.bing.com/search?q=test",
              _validator_html("b_algo", "b_results")),
    ProbeSpec("qwant",
              "https://api.qwant.com/v3/search/web?q=test&count=1&locale=en_US",
              _validator_qwant_json),
    ProbeSpec("wikipedia",
              "https://en.wikipedia.org/w/api.php?action=opensearch&search=test",
              _validator_wikipedia_json),
]


# ---------- rolling state ----------


@dataclasses.dataclass
class Stat:
    success: float = 0.0         # EWMA in [0,1]
    latency_ms: float = 10_000.0  # EWMA
    samples: int = 0

    def update(self, ok: bool, latency_ms: float) -> None:
        s = 1.0 if ok else 0.0
        self.success = ALPHA * s + (1.0 - ALPHA) * self.success
        self.latency_ms = ALPHA * latency_ms + (1.0 - ALPHA) * self.latency_ms
        self.samples += 1

    def score(self) -> float:
        # Higher is better. Penalize slow proxies and reward reliability.
        # +100ms floor prevents divide-by-near-zero and smooths extremes.
        return self.success / (self.latency_ms + 100.0)


STATE: dict[tuple[str, str], Stat] = {}


def _state_key(engine: str, proxy: str) -> tuple[str, str]:
    return (engine, proxy)


def _get_stat(engine: str, proxy: str) -> Stat:
    k = _state_key(engine, proxy)
    if k not in STATE:
        STATE[k] = Stat()
    return STATE[k]


# ---------- probing ----------


def probe(engine: ProbeSpec, proxy_url: str) -> tuple[bool, float]:
    """Probe one (engine, proxy). Returns (success, latency_ms)."""
    t0 = time.monotonic()
    try:
        r = _client_for(proxy_url).get(engine.url, headers={
            "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) searxng-ranker/1.0",
            "Accept-Language": "en-US,en;q=0.9",
        })
        lat = (time.monotonic() - t0) * 1000.0
        if r.status_code != 200:
            return False, lat
        return engine.validator(r.text), lat
    except Exception:
        return False, PROBE_TIMEOUT * 1000.0


def run_cycle(cycle_id: int) -> None:
    if not PROXIES:
        log.warning("[cycle=%d] no proxies configured, skipping", cycle_id)
        return

    for engine in ENGINES:
        order = list(PROXIES)
        random.shuffle(order)
        wins = 0
        total_lat = 0.0
        for proxy in order:
            ok, lat = probe(engine, proxy)
            _get_stat(engine.name, proxy).update(ok, lat)
            if ok:
                wins += 1
                total_lat += lat
            time.sleep(random.uniform(0.05, 0.2))
        avg_lat = (total_lat / wins) if wins else 0.0
        log.info("[cycle=%d] engine=%s probes=%d success=%d avg_latency=%.0fms",
                 cycle_id, engine.name, len(order), wins, avg_lat)


# ---------- ranking + rendering ----------


def ranked_proxies_for(engine: str) -> list[str]:
    scored = [(p, _get_stat(engine, p).score()) for p in PROXIES]
    scored.sort(key=lambda t: t[1], reverse=True)
    return [p for p, _ in scored]


def ranked_proxies_global() -> list[str]:
    # Average score across engines, so global fallback prefers generally-good proxies.
    overall: list[tuple[str, float]] = []
    for p in PROXIES:
        scores = [_get_stat(e.name, p).score() for e in ENGINES]
        overall.append((p, sum(scores) / max(1, len(scores))))
    overall.sort(key=lambda t: t[1], reverse=True)
    return [p for p, _ in overall]


def has_any_measurements() -> bool:
    return any(s.samples > 0 for s in STATE.values())


def render_settings_yaml(current_yaml: str) -> str:
    """Parse existing settings.yml, inject ranked proxies at global + per-engine,
    return new YAML string."""
    doc = yaml.safe_load(current_yaml)
    if not isinstance(doc, dict):
        raise RuntimeError("settings.yml did not parse as a mapping")

    # Global fallback list: all proxies, ranked by overall score.
    outgoing = doc.setdefault("outgoing", {})
    outgoing_proxies = outgoing.setdefault("proxies", {})
    outgoing_proxies["all://"] = ranked_proxies_global()

    # Per-engine top-N.
    engines = doc.get("engines", [])
    if not isinstance(engines, list):
        engines = []
    by_name: dict[str, dict[str, Any]] = {}
    for e in engines:
        if isinstance(e, dict) and "name" in e:
            by_name[e["name"]] = e

    for spec in ENGINES:
        top = ranked_proxies_for(spec.name)[:TOP_N]
        # Drop proxies with zero success — they waste retries.
        top = [p for p in top if _get_stat(spec.name, p).score() > 0] or top[:TOP_N]
        entry = by_name.get(spec.name)
        if entry is None:
            continue  # engine not in settings.yml's engines list; skip
        entry["proxies"] = {"all://": top}

    return yaml.safe_dump(doc, sort_keys=False, default_flow_style=False, width=4096)


# ---------- kubernetes I/O ----------


def load_k8s() -> client.CoreV1Api:
    config.load_incluster_config()
    return client.CoreV1Api()


def read_settings_yaml(core: client.CoreV1Api) -> str:
    cm = core.read_namespaced_config_map(CONFIGMAP, NAMESPACE)
    if cm.data is None or "settings.yml" not in cm.data:
        raise RuntimeError(f"ConfigMap {NAMESPACE}/{CONFIGMAP} missing settings.yml key")
    return cm.data["settings.yml"]


def patch_settings_yaml(core: client.CoreV1Api, new_yaml: str) -> None:
    core.patch_namespaced_config_map(
        name=CONFIGMAP,
        namespace=NAMESPACE,
        body={"data": {"settings.yml": new_yaml}},
    )


# ---------- health endpoint ----------


class HealthHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"ok")
        else:
            self.send_error(404)

    def log_message(self, format: str, *args: Any) -> None:
        return  # suppress access logs


def start_health_server(port: int) -> None:
    srv = HTTPServer(("0.0.0.0", port), HealthHandler)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    log.info("health server listening on :%d", port)


# ---------- main loop ----------


def main() -> None:
    log.info("searxng-ranker starting: %d proxies, interval=%ds, top_n=%d",
             len(PROXIES), INTERVAL, TOP_N)
    if not PROXIES:
        log.error("no EXITNODE_PROXIES configured; exiting")
        sys.exit(1)

    start_health_server(HEALTH_PORT)
    core = load_k8s()

    cycle = 0
    while True:
        cycle += 1
        try:
            run_cycle(cycle)
            if not has_any_measurements():
                log.warning("[cycle=%d] no measurements recorded; skipping write", cycle)
            else:
                current = read_settings_yaml(core)
                new_yaml = render_settings_yaml(current)
                if new_yaml != current:
                    patch_settings_yaml(core, new_yaml)
                    log.info("[cycle=%d] settings.yml updated; Reloader will roll searxng", cycle)
                else:
                    log.info("[cycle=%d] settings.yml unchanged; no rollout", cycle)
        except Exception as exc:
            log.exception("[cycle=%d] failed: %s", cycle, exc)

        log.info("[cycle=%d] sleeping %ds", cycle, INTERVAL)
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
