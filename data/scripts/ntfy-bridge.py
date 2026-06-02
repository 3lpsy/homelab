"""Alertmanager-to-ntfy bridge.

Receives Alertmanager webhook POSTs on /alertmanager/pod-state, reformats
each alert into a human-readable notification with emoji, severity-based
priority, and label details, then forwards to ntfy via its JSON publish API.
The Authorization header from the incoming request is passed through to ntfy.

Usage:
    python3 ntfy-bridge.py --ntfy-url https://ntfy.example.com --ntfy-topic homelab [--port 8085]
"""

from __future__ import annotations

import argparse
import json
import logging
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    stream=sys.stdout,
)
log: logging.Logger = logging.getLogger("ntfy-bridge")

SEVERITY_EMOJI: dict[str, str] = {
    "critical": "\U0001f6a8",  # rotating light
    "warning": "\U0001f525",  # fire
    "info": "\u2139\ufe0f",  # info
}
RESOLVED_EMOJI: str = "\u2705"  # green check

SEVERITY_PRIORITY: dict[str, str] = {
    "critical": "urgent",
    "warning": "high",
    "info": "default",
}

PRIORITY_TO_INT: dict[str, int] = {
    "min": 1,
    "low": 2,
    "default": 3,
    "high": 4,
    "urgent": 5,
}


def format_alert(alert: dict[str, Any]) -> tuple[str, str, str, list[str]]:
    """Format a single Alertmanager alert into ntfy fields.

    Returns (title, message, priority, tags).
    """
    status: str = alert.get("status", "unknown")
    labels: dict[str, str] = alert.get("labels", {})
    annotations: dict[str, str] = alert.get("annotations", {})

    alert_name: str = labels.get("alertname", "Unknown Alert")
    severity: str = labels.get("severity", "warning")
    summary: str = annotations.get("summary", "")
    description: str = annotations.get("description", "")

    if status == "resolved":
        emoji = RESOLVED_EMOJI
        title = f"{emoji} Resolved: {alert_name}"
        priority = "default"
        tags: list[str] = ["white_check_mark"]
    else:
        emoji = SEVERITY_EMOJI.get(severity, SEVERITY_EMOJI["warning"])
        title = f"{emoji} {alert_name}"
        priority = SEVERITY_PRIORITY.get(severity, "default")
        tags = ["warning"] if severity == "warning" else [severity]

    lines: list[str] = []
    if summary:
        lines.append(summary)
    if description:
        lines.append(description)

    detail_labels: dict[str, str] = {k: v for k, v in labels.items() if k not in ("alertname", "severity")}
    if detail_labels:
        lines.append("")
        for k, v in detail_labels.items():
            lines.append(f"{k}: {v}")

    message: str = "\n".join(lines) if lines else alert_name

    return title, message, priority, tags


class BridgeHandler(BaseHTTPRequestHandler):
    """HTTP handler that accepts Alertmanager webhooks on configured routes."""

    ntfy_url: str = ""
    ntfy_topic: str = ""

    def do_POST(self) -> None:
        if self.path != "/alertmanager/pod-state":
            self.send_error(404, "Not Found")
            return

        content_length: int = int(self.headers.get("Content-Length", 0))
        if content_length == 0:
            self.send_error(400, "Empty request body")
            return

        raw: bytes = self.rfile.read(content_length)

        try:
            payload: dict[str, Any] = json.loads(raw)
        except json.JSONDecodeError as exc:
            log.error("Invalid JSON: %s", exc)
            self.send_error(400, f"Invalid JSON: {exc}")
            return

        alerts: list[dict[str, Any]] = payload.get("alerts", [])
        if not alerts:
            log.warning("Webhook contained no alerts")
            self.send_error(400, "No alerts in payload")
            return

        auth_header: str | None = self.headers.get("Authorization")
        errors: list[str] = []

        for alert in alerts:
            title, message, priority, tags = format_alert(alert)

            try:
                self._forward_to_ntfy(title, message, priority, tags, auth_header)
                log.info("Forwarded alert: %s (%s)", title, alert.get("status"))
            except (HTTPError, URLError, OSError) as exc:
                error_msg = f"Failed to forward alert '{title}': {exc}"
                log.error(error_msg)
                errors.append(error_msg)

        if errors:
            body: bytes = json.dumps({"errors": errors}).encode()
            self.send_response(502)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"ok")

    def do_GET(self) -> None:
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"ok")
            return
        self.send_error(404, "Not Found")

    def _forward_to_ntfy(
        self,
        title: str,
        message: str,
        priority: str,
        tags: list[str],
        auth_header: str | None,
    ) -> None:
        ntfy_payload: dict[str, Any] = {
            "topic": self.ntfy_topic,
            "title": title,
            "message": message,
            "priority": PRIORITY_TO_INT.get(priority, 3),
            "tags": tags,
        }

        body: bytes = json.dumps(ntfy_payload, ensure_ascii=False).encode()
        headers: dict[str, str] = {"Content-Type": "application/json"}
        if auth_header:
            headers["Authorization"] = auth_header

        req = Request(
            self.ntfy_url,
            data=body,
            headers=headers,
            method="POST",
        )

        with urlopen(req, timeout=10) as resp:
            resp.read()

    def log_message(self, format: str, *args: Any) -> None:
        """Route BaseHTTPRequestHandler logs through the logging module."""
        log.info(format, *args)


def main() -> None:
    parser = argparse.ArgumentParser(description="Alertmanager-to-ntfy bridge")
    parser.add_argument("--ntfy-url", required=True, help="ntfy server base URL (e.g. https://ntfy.example.com)")
    parser.add_argument("--ntfy-topic", required=True, help="ntfy topic name (e.g. homelab)")
    parser.add_argument("--port", type=int, default=8085, help="Port to listen on (default: 8085)")
    args: argparse.Namespace = parser.parse_args()

    BridgeHandler.ntfy_url = args.ntfy_url
    BridgeHandler.ntfy_topic = args.ntfy_topic

    server = HTTPServer(("0.0.0.0", args.port), BridgeHandler)
    log.info("Listening on :%d, forwarding to %s (topic: %s)", args.port, args.ntfy_url, args.ntfy_topic)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Shutting down")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
