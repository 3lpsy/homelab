#!/usr/bin/env bash
# Run a Trivy k8s scan via Podman, write JSON + table + Markdown reports
# into ./reports. DB cache persisted in ./.trivy-cache. Exceptions in
# ./exceptions/.trivyignore.
#
# Run from the security/ directory: ./trivy.sh
#
# Requires: $KUBECONFIG set on the host, kubectl, jq, podman.
#
# Override scanners, severity, or timeout:
#   TRIVY_SCANNERS=secret,misconfig,rbac ./trivy.sh   # skip image vuln pulls
#   TRIVY_SEVERITY=MEDIUM,HIGH,CRITICAL ./trivy.sh
#   TRIVY_TIMEOUT=4h ./trivy.sh                       # default 2h

set -euo pipefail

cd "$(dirname "$0")"

: "${KUBECONFIG:?KUBECONFIG is not set on the host}"
[[ -f "$KUBECONFIG" ]] || { echo "kubeconfig not found at $KUBECONFIG" >&2; exit 1; }

mkdir -p reports .trivy-cache

# Flatten kubeconfig so cert/key data is inlined (no host-fs path refs leak
# into the container).
FLAT=$(mktemp)
trap 'rm -f "$FLAT"' EXIT
kubectl --kubeconfig="$KUBECONFIG" config view --raw --flatten > "$FLAT"
chmod 0644 "$FLAT"

IMG="ghcr.io/aquasecurity/trivy:latest"
SCANNERS="${TRIVY_SCANNERS:-vuln,misconfig,secret,rbac}"
SEVERITY="${TRIVY_SEVERITY:-HIGH,CRITICAL}"
TIMEOUT="${TRIVY_TIMEOUT:-2h}"
EXC="$PWD/exceptions/.trivyignore"

run_scan() {
  local fmt="$1" out="$2"
  podman run --rm \
    --userns=keep-id \
    -e KUBECONFIG=/kc/config \
    -e TRIVY_CACHE_DIR=/cache \
    -v "$FLAT:/kc/config:ro,Z" \
    -v "$PWD/.trivy-cache:/cache:Z" \
    -v "$EXC:/etc/trivy/.trivyignore:ro,Z" \
    -v "$PWD/trivy.yaml:/etc/trivy/trivy.yaml:ro,Z" \
    -v "$PWD/reports:/out:Z" \
    "$IMG" \
      --config /etc/trivy/trivy.yaml -d \
    k8s \
      --scanners "$SCANNERS" \
      --severity "$SEVERITY" \
      --timeout "$TIMEOUT" \
      --ignorefile /etc/trivy/.trivyignore \
      --format "$fmt" \
      --output "/out/$out"
}

echo ">> JSON scan"
run_scan json trivy-report.json

echo ">> Markdown summary"
jq -r '
  def sev_rank: if . == "CRITICAL" then 0 elif . == "HIGH" then 1 elif . == "MEDIUM" then 2 elif . == "LOW" then 3 else 4 end;

  "# Trivy k8s scan",
  "",
  "- **Cluster:** \(.ClusterName // "(unnamed)")",
  "- **Generated:** \(now | strftime("%Y-%m-%dT%H:%M:%SZ"))",
  "",
  "## Findings by severity",
  "",
  "| Severity | Vulnerabilities | Misconfigurations | Secrets |",
  "|----------|-----------------|-------------------|---------|",
  ( [ .Resources[]?.Results[]? | (
        (.Vulnerabilities[]?       | {sev: .Severity, kind: "vuln"}),
        (.Misconfigurations[]?     | {sev: .Severity, kind: "misconfig"}),
        (.Secrets[]?               | {sev: .Severity, kind: "secret"})
      ) ]
    | group_by(.sev)
    | sort_by(.[0].sev | sev_rank)
    | map({
        sev: .[0].sev,
        vuln: ([.[] | select(.kind=="vuln")] | length),
        misc: ([.[] | select(.kind=="misconfig")] | length),
        sec:  ([.[] | select(.kind=="secret")] | length)
      })
    | .[]
    | "| \(.sev) | \(.vuln) | \(.misc) | \(.sec) |"
  ),
  "",
  "## Top resources (by total findings)",
  "",
  "| Namespace | Kind | Name | Findings |",
  "|-----------|------|------|----------|",
  ( [ .Resources[]? | {
        ns: .Namespace, kind: .Kind, name: .Name,
        n: ([.Results[]? | (.Vulnerabilities // []) + (.Misconfigurations // []) + (.Secrets // []) | length] | add // 0)
      } ]
    | map(select(.n > 0))
    | sort_by(-.n)
    | .[:20]
    | .[]
    | "| \(.ns) | \(.kind) | \(.name) | \(.n) |"
  ),
  "",
  "## Secrets detected (full list)",
  "",
  "| Namespace | Kind | Name | RuleID | Severity | Title |",
  "|-----------|------|------|--------|----------|-------|",
  ( [ .Resources[]? as $r | $r.Results[]? | .Secrets[]? as $s
      | "| \($r.Namespace) | \($r.Kind) | \($r.Name) | \($s.RuleID) | \($s.Severity) | \($s.Title) |" ]
    | .[]
  )
' reports/trivy-report.json > reports/trivy-report.md

echo
echo "Reports: reports/trivy-report.{json,md}"
