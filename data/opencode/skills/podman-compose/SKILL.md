---
name: podman-compose
description: Bring up a multi-container stack from a docker-compose.yml / compose.yaml inside this pod using `podman compose` (Docker Compose v2 frontend, podman engine). Use when a repo has a compose file or you need several containers wired together for testing.
---
# podman-compose

This pod runs **`podman compose`** — the Docker Compose v2 CLI
(`docker-compose` binary) driving **rootless podman** as the engine.
There is NO Docker daemon. Use it for compose-file-defined dev
stacks (app + db + cache, etc.).

## The one rule: invoke `podman compose`, never bare `docker-compose`

    podman compose up -d
    podman compose ps
    podman compose logs -f <service>
    podman compose down

`podman compose` wires the docker-compose frontend to a transient
podman socket. Running bare `docker-compose` would hunt for a Docker
daemon that does not exist here and fail with a socket error. If you
see "Cannot connect to the Docker daemon", you ran the wrong one —
re-run with `podman compose`.

Full compose-spec v2 syntax is supported (it IS the docker-compose
binary): `build:`, `depends_on:`, `healthcheck:`, profiles, etc.

## Rootless constraints carry over (see the `podman` skill)

- Engine is rootless podman as `user` — `privileged: true` in a
  compose service is meaningless (maps to your userns, not host
  root); don't add it to chase a permission error.
- Networking is slirp4netns: inter-service DNS by compose service
  name works; published ports bind on the pod, reachable from your
  session but not the wider cluster.
- Images pull through the in-cluster docker.io/ghcr.io mirrors
  automatically — reference base images by normal name.
- The image/volume store is an ephemeral emptyDir — a `podman
  compose down` + pod restart loses everything. Named volumes
  persist only for the pod's lifetime. Don't store anything you
  need to keep there.

## Workflow

1. Confirm a `compose.yaml` / `docker-compose.yml` exists (usually
   in the working repo).
2. `podman compose up -d` to start detached; `podman compose ps`
   to confirm health.
3. `podman compose logs -f <service>` to debug a service that won't
   come up.
4. `podman compose down -v` to tear down AND drop the volumes when
   finished — leaving stacks running wastes the pod's cpu/mem
   budget.

For a single ad-hoc container (not a compose file), use the
`podman` skill instead.
