#!/usr/bin/env bash
#
# shutdown-artemis.sh — gracefully evict workloads off the artemis GPU node and
# cordon it ahead of a power-off (e.g. chassis-fan replacement).
#
# Steps:
#   1. show what's currently scheduled on artemis
#   2. cordon it (no new pods land here)
#   3. drain it (graceful termination of its pods — Frigate, LLM, etc.)
#
# After this completes the box is safe to power off. artemis's stateful data
# (Frigate recordings + any other local-path PVC) is node-local, so the drained
# pods can't move elsewhere — they sit Pending until artemis is back and
# uncordoned. That's expected for a temporary outage.
#
# Bring it back after power-on (once the node shows Ready):
#
# Requires kubectl access to the cluster (tailnet up). Override the node name
# by passing it as the first arg.

set -euo pipefail

NODE="${1}"

echo "==> Target node: $NODE"
kubectl get node "$NODE" -o wide

echo
echo "==> Pods currently on $NODE (these get gracefully evicted):"
kubectl get pods -A --field-selector "spec.nodeName=$NODE" -o wide

echo
read -r -p "Proceed to cordon + drain $NODE? [y/N] " ans
case "$ans" in
  [yY] | [yY][eE][sS]) ;;
  *) echo "Aborted — nothing changed."; exit 1 ;;
esac

echo
echo "==> Cordoning $NODE (mark unschedulable) ..."
kubectl cordon "$NODE"

echo
echo "==> Draining $NODE (graceful eviction; daemonsets ignored, emptyDir dropped) ..."
# No --force on purpose: if drain complains about a pod not managed by a
# controller, inspect it rather than blindly deleting it, then re-run with
# --force if you're sure.
kubectl drain "$NODE" \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --grace-period=120 \
  --timeout=300s

echo
echo "==> Done. $NODE is cordoned and drained — safe to power off now."
echo "    (Its GPU/stateful pods will sit Pending until the node returns.)"
echo
echo "After power-on, when '$NODE' shows Ready:"
echo "    kubectl uncordon $NODE"
