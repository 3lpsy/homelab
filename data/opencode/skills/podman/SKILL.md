---
name: podman
description: Run, build, and manage throwaway dev containers with rootless podman inside this pod. Use for `podman run/build/exec/ps/logs/images`, spinning up a DB/service for testing, or building an image from a Dockerfile.
---
# podman

This pod ships **rootless podman** so you can spin up throwaway
containers for development — a Postgres to test against, a clean
build environment, running a Dockerfile, etc. You run as the
unprivileged `user`; podman is rootless. There is NO Docker daemon
and NO host container runtime involved — these containers live and
die with this pod.

## What works, and the constraints that follow from rootless

- `podman run`, `build`, `exec`, `ps`, `images`, `logs`, `rm`, `pull`
  all work normally. Use them as you would docker.
- You are NOT root on the host. A container's "root" is your `user`
  mapped through a subuid range — fine for installing packages and
  writing files INSIDE the container, but it cannot touch the host
  or escape. `--privileged` is meaningless here (it maps to your
  unprivileged userns, not host root); don't reach for it to "fix"
  a permission error.
- Networking is **slirp4netns** (userspace). Outbound works and NATs
  out as this pod's own egress, so a container can reach the
  internet exactly where the pod is allowed to. Port publishing
  (`-p 8080:80`) binds on the pod's loopback/eth0 — reachable from
  other containers in this pod and from your own session, not from
  the wider cluster (netpol default-deny still applies).
- The image store is an **ephemeral emptyDir** — pulled/built images
  do NOT survive a pod restart. That's intentional; re-pull is fast
  (see mirrors below). Don't treat it as durable storage.

## Base images pull through in-cluster mirrors automatically

`docker.io` and `ghcr.io` are mirrored in-cluster (registries.conf
is already configured), so `podman pull docker.io/library/postgres`
goes through the local proxy and dodges Docker Hub's anonymous
rate limit. Just pull by normal name — no special flags.

## Storage driver

`podman info --format '{{.Store.GraphDriverName}}'` should say
`overlay` (native rootless overlay). If it ever says `vfs`,
everything still works but is slower and fatter — flag it, don't
try to "fix" the storage config yourself (it's baked in the image).

## When to use vs. not

- USE for: ephemeral test deps (DBs, queues, mock services), running
  a project's own `Dockerfile`, reproducing CI in a clean image.
- DON'T use to deploy anything to the cluster — these are local,
  throwaway, and invisible to k3s. For real workloads the target is
  Terraform, not podman.

For multi-container stacks defined in a compose file, use the
`podman-compose` skill instead.
