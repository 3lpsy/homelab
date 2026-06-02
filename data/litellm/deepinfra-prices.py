#!/usr/bin/env python3
import sys

import requests

MODELS = [
    "openai/gpt-oss-120b",
    "zai-org/GLM-4.5-Air",
    "Qwen/Qwen3-Next-80B-A3B-Instruct",
    "Qwen/Qwen3.6-35B-A3B",
    "zai-org/GLM-4.7-Flash",
    "google/gemma-4-31B-it",
    "Qwen/Qwen3.5-4B",
    "Qwen/Qwen3.5-2B",
    "openai/gpt-oss-20b",
    "Qwen/Qwen3.5-27B",
]

BASE = "https://api.deepinfra.com/models"


def to_usd_per_token(pricing):
    inp = pricing.get("cents_per_input_token")
    out = pricing.get("cents_per_output_token")
    if inp is None and pricing.get("input_tokens_per_dollar"):
        inp = 100.0 / pricing["input_tokens_per_dollar"]
    if out is None and pricing.get("output_tokens_per_dollar"):
        out = 100.0 / pricing["output_tokens_per_dollar"]
    return (
        inp / 100.0 if inp is not None else None,
        out / 100.0 if out is not None else None,
    )


def fetch(model_id):
    r = requests.get(f"{BASE}/{model_id}", timeout=10)
    if r.status_code == 404:
        return None
    r.raise_for_status()
    return r.json()


def main():
    models = sys.argv[1:] or MODELS
    for model_id in models:
        try:
            data = fetch(model_id)
        except requests.RequestException as e:
            print(f"# {model_id}: request failed: {e}", file=sys.stderr)
            continue
        if data is None:
            print(f"# {model_id}: 404 not found")
            continue
        pricing = data.get("pricing") or {}
        inp, out = to_usd_per_token(pricing)
        print(f"# {model_id}")
        print(f"#   raw: {pricing}")
        if inp is not None:
            print(f"    input_cost_per_token:  {inp:.10f}")
        if out is not None:
            print(f"    output_cost_per_token: {out:.10f}")
        print()


if __name__ == "__main__":
    main()
