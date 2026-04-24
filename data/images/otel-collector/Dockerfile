# OpenTelemetry Collector (contrib) with journalctl available.
#
# Upstream otel/opentelemetry-collector-contrib uses a distroless base that has
# no journalctl binary, so the collector's journald receiver fails to start
# (it shells out to `journalctl`). We rebase the upstream binary on debian-slim
# with systemd installed so the receiver works.
#
# Why debian-slim instead of alpine: alpine's package repos don't carry a
# `systemd` package (alpine uses OpenRC), so `apk add systemd` fails.
#
# Bumping the upstream version: change the `FROM otel/...` tag below; the
# Dockerfile-hash trigger in nextcloud/otel-collector-jobs.tf will rebuild.
FROM otel/opentelemetry-collector-contrib:0.150.1 AS upstream

FROM debian:12-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends systemd ca-certificates tzdata \
    && rm -rf /var/lib/apt/lists/*
COPY --from=upstream /otelcol-contrib /otelcol-contrib

LABEL homelab.mirror="open-telemetry/opentelemetry-collector-contrib"
LABEL homelab.upstream-version="0.150.1"

# Match the UID/GID the DaemonSet pod spec uses so host PVC / journal ACLs
# align. systemd-journal group on the K3s host is gid 190, set as a
# supplementalGroup on the pod (not here, since groups must exist at runtime).
USER 10001:10001

ENTRYPOINT ["/otelcol-contrib"]
CMD ["--config=/etc/otelcol/config.yaml"]
