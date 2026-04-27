#!/usr/bin/env bash
# Run a Kubescape posture scan via Podman, write JSON + HTML + Markdown
# reports into ./reports. Exceptions are loaded from ./exceptions.
#
# Run from the security/ directory: ./kubescape.sh
#
# Requires: $KUBECONFIG set on the host, kubectl, jq, podman.

set -euo pipefail

cd "$(dirname "$0")"

: "${KUBECONFIG:?KUBECONFIG is not set on the host}"
[[ -f "$KUBECONFIG" ]] || { echo "kubeconfig not found at $KUBECONFIG" >&2; exit 1; }

mkdir -p reports

# Flatten kubeconfig so cert/key data is inlined (no host-fs path refs leak
# into the container).
FLAT=$(mktemp)
trap 'rm -f "$FLAT"' EXIT
kubectl --kubeconfig="$KUBECONFIG" config view --raw --flatten > "$FLAT"
chmod 0644 "$FLAT"

IMG="quay.io/kubescape/kubescape-cli:latest"
EXC="$PWD/exceptions/kubescape-exceptions.json"

run_scan() {
  local fmt="$1" out="$2"
  podman run --rm \
    --userns=keep-id:uid=65532,gid=65532 \
    -e KUBECONFIG=/kc/config \
    -v "$FLAT:/kc/config:ro,Z" \
    -v "$EXC:/exc.json:ro,Z" \
    -v "$PWD/reports:/out:Z" \
    "$IMG" \
    scan --submit=false \
         --exceptions /exc.json \
         --format "$fmt" --output "/out/$out"
}

echo ">> JSON scan"
run_scan json report.json

echo ">> HTML scan"
run_scan html report.html

echo ">> Markdown summary"
jq -r '
  def sev_rank: if . == "Critical" then 0 elif . == "High" then 1 elif . == "Medium" then 2 elif . == "Low" then 3 else 4 end;
  def round2: . * 100 | round / 100;

  "# Kubescape Scan Report",
  "",
  "- **Cluster:** \(if .clusterName == "" then "(unnamed)" else .clusterName end)",
  "- **Generated:** \(.generationTime)",
  "- **Status:** \(.summaryDetails.status)",
  "- **Compliance Score:** \(.summaryDetails.complianceScore | round2)%",
  "- **Risk Score:** \(.summaryDetails.score | round2)",
  "- **Frameworks:** \([.summaryDetails.frameworks[].name] | join(", "))",
  "",
  "## Severity totals",
  "",
  "| Severity | Failed controls | Failed resources |",
  "|----------|-----------------|------------------|",
  "| Critical | \(.summaryDetails.controlsSeverityCounters.criticalSeverity) | \(.summaryDetails.resourcesSeverityCounters.criticalSeverity) |",
  "| High | \(.summaryDetails.controlsSeverityCounters.highSeverity) | \(.summaryDetails.resourcesSeverityCounters.highSeverity) |",
  "| Medium | \(.summaryDetails.controlsSeverityCounters.mediumSeverity) | \(.summaryDetails.resourcesSeverityCounters.mediumSeverity) |",
  "| Low | \(.summaryDetails.controlsSeverityCounters.lowSeverity) | \(.summaryDetails.resourcesSeverityCounters.lowSeverity) |",
  "",
  "## Failed controls",
  "",
  "| Control | Severity | Name | Failed | Passed | Compliance |",
  "|---------|----------|------|--------|--------|------------|",
  (.summaryDetails.controls
    | to_entries
    | map(select(.value.status == "failed"))
    | sort_by([(.value.severity | sev_rank), -(.value.ResourceCounters.failedResources)])
    | .[]
    | "| \(.key) | \(.value.severity) | \(.value.name) | \(.value.ResourceCounters.failedResources) | \(.value.ResourceCounters.passedResources) | \(.value.complianceScore | round2)% |")
' reports/report.json > reports/report.md

echo
echo "Reports: reports/report.{json,html,md}"
