#!/usr/bin/env bash
#
# shutdown-delphi.sh — gracefully evict workloads off the delphi control-plane
# node and cordon it ahead of a power-off.
#
# DELPHI IS NOT ARTEMIS. delphi runs the K3s control plane (apiserver, etcd/sqlite)
# AND hosts every stateful local-path PVC (/var/lib/rancher/k3s/storage). Draining
# it takes the WHOLE cluster down, not just delphi's pods — there is nowhere for
# its pods to move. Only do this when you genuinely mean to power the cluster off.
#
# Steps:
#   1. show what's currently scheduled on delphi
#   2. cordon it (no new pods land here)
#   3. drain it (graceful termination of its pods)
#
# Order matters on the way down and back up:
#   - Bring artemis down FIRST (shutdown-artemis.sh), delphi LAST. delphi serves
#     the apiserver artemis's drain talks to.
#   - On the way back, delphi FIRST. Nothing else can come up until the apiserver
#     and Vault are healthy — Vault is the init gate (see docs power-loss runbook).
#
# After power-on, when 'delphi' shows Ready:
# Then unseal Vault before expecting other workloads to settle.
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
echo "!!  WARNING: $NODE is the K3s control plane + stateful PVC host."
echo "!!  Draining it takes the ENTIRE cluster offline. Make sure artemis is"
echo "!!  already down and you mean to power the whole cluster off."
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
echo "    (The cluster is effectively down until delphi returns.)"
echo
echo "After power-on, when '$NODE' shows Ready:"
echo "    kubectl uncordon $NODE"
echo "    # then unseal Vault — it gates every other workload's init"
