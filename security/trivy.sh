#!/usr/bin/env bash
# Run a Trivy k8s scan via Podman, write JSON + table + Markdown reports
# into ./reports. DB cache persisted in ./.trivy-cache. Exceptions in
# ./exceptions/.trivyignore.
#
# Run from the security/ directory:
#   ./trivy.sh                # full scan + JSON + MD
#   ./trivy.sh md-only        # regenerate MD from existing reports/trivy-report.json
#
# Requires: $KUBECONFIG set on the host, kubectl, jq, podman.
#
# Override scanners, severity, or timeout (scan mode only):
#   TRIVY_SCANNERS=secret,misconfig,rbac ./trivy.sh   # skip image vuln pulls
#   TRIVY_SEVERITY=MEDIUM,HIGH,CRITICAL ./trivy.sh
#   TRIVY_TIMEOUT=4h ./trivy.sh                       # default 2h

set -euo pipefail

cd "$(dirname "$0")"

mkdir -p reports

MODE="${1:-scan}"

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

regen_md() {
  [[ -f reports/trivy-report.json ]] || { echo "reports/trivy-report.json missing — run scan first" >&2; exit 1; }
  echo ">> Markdown summary"
  jq -r '
  def sev_rank: if . == "CRITICAL" then 0 elif . == "HIGH" then 1 elif . == "MEDIUM" then 2 elif . == "LOW" then 3 else 4 end;
  def cell: (. // "") | tostring | gsub("\n"; " ") | gsub("\\|"; "\\|");
  def trim($n): if (. | length) > $n then .[0:$n] + "…" else . end;

  . as $root
  | [
      .Resources[]? as $r
      | $r.Results[]? as $rs
      | (
          ($rs.Vulnerabilities[]?   | {kind:"vuln",     sev:.Severity, id:.VulnerabilityID, pkg:.PkgName, installed:(.InstalledVersion // ""), fixed:(.FixedVersion // ""), title:(.Title // ""), ns:($r.Namespace // ""), kind_k:$r.Kind, name:$r.Name, target:($rs.Target // "")}),
          ($rs.Misconfigurations[]? | {kind:"misconfig", sev:.Severity, id:.ID,              title:(.Title // ""), msg:(.Message // ""), ns:($r.Namespace // ""), kind_k:$r.Kind, name:$r.Name, target:($rs.Target // "")}),
          ($rs.Secrets[]?           | {kind:"secret",    sev:.Severity, id:.RuleID,          title:(.Title // ""), ns:($r.Namespace // ""), kind_k:$r.Kind, name:$r.Name, target:($rs.Target // "")})
        )
    ] as $all

  | "# Trivy k8s scan",
    "",
    "- **Cluster:** \($root.ClusterName // "(unnamed)")",
    "- **Generated:** \(now | strftime("%Y-%m-%dT%H:%M:%SZ"))",
    "- **Total findings:** \($all | length)",
    "",
    "## Findings by severity",
    "",
    "| Severity | Vulnerabilities | Misconfigurations | Secrets |",
    "|----------|-----------------|-------------------|---------|",
    ( $all
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
    "## Top resources (by total findings, deduped across scan targets)",
    "",
    "| Namespace | Kind | Name | Findings |",
    "|-----------|------|------|----------|",
    ( $all
      | group_by([.ns, .kind_k, .name])
      | map({ns: .[0].ns, kind_k: .[0].kind_k, name: .[0].name, n: length})
      | sort_by(-.n)
      | .[:20]
      | .[]
      | "| \(.ns | cell) | \(.kind_k | cell) | \(.name | cell) | \(.n) |"
    ),
    "",
    "## Top 30 vulnerabilities (by frequency)",
    "",
    "| CVE | Severity | Occurrences | Package(s) |",
    "|-----|----------|-------------|------------|",
    ( [ $all[] | select(.kind=="vuln") ]
      | group_by(.id)
      | map({id: .[0].id, sev: .[0].sev, n: length, pkgs: ([.[].pkg | tostring] | unique | join(", ") | trim(80))})
      | sort_by([(.sev | sev_rank), (-.n)])
      | .[:30]
      | .[]
      | "| \(.id | cell) | \(.sev) | \(.n) | \(.pkgs | cell) |"
    ),
    "",
    "## CRITICAL vulnerabilities (full detail)",
    "",
    "| CVE | Package | Installed | Fixed | Target |",
    "|-----|---------|-----------|-------|--------|",
    ( [ $all[] | select(.kind=="vuln" and .sev=="CRITICAL") ]
      | sort_by([.id, .target])
      | .[]
      | "| \(.id | cell) | \(.pkg | cell) | \(.installed | cell) | \(.fixed | cell) | \(.target | cell) |"
    ),
    "",
    "## Misconfigurations (CRITICAL + HIGH)",
    "",
    "| Rule | Severity | Target | Message |",
    "|------|----------|--------|---------|",
    ( [ $all[] | select(.kind=="misconfig" and (.sev=="CRITICAL" or .sev=="HIGH")) ]
      | sort_by([(.sev | sev_rank), .id, .target])
      | .[]
      | "| \(.id | cell) | \(.sev) | \(.target | cell) | \(.msg | trim(140) | cell) |"
    ),
    "",
    "## Secrets detected (full list)",
    "",
    "| Namespace | Kind | Name | RuleID | Severity | Title |",
    "|-----------|------|------|--------|----------|-------|",
    ( [ $all[] | select(.kind=="secret") ]
      | .[]
      | "| \(.ns | cell) | \(.kind_k | cell) | \(.name | cell) | \(.id | cell) | \(.sev) | \(.title | cell) |"
    )
' reports/trivy-report.json > reports/trivy-report.md
}

case "$MODE" in
  md-only)
    regen_md
    echo
    echo "Reports: reports/trivy-report.md (regenerated from existing JSON)"
    ;;
  scan)
    : "${KUBECONFIG:?KUBECONFIG is not set on the host}"
    [[ -f "$KUBECONFIG" ]] || { echo "kubeconfig not found at $KUBECONFIG" >&2; exit 1; }
    mkdir -p .trivy-cache

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

    echo ">> JSON scan"
    run_scan json trivy-report.json
    regen_md
    echo
    echo "Reports: reports/trivy-report.{json,md}"
    ;;
  *)
    echo "usage: $0 [scan|md-only]" >&2
    exit 2
    ;;
esac
