# syntax=docker/dockerfile:1.4
#
# Builds a single-file artifact image for the Frigate ONNX detector. The build
# stage clones WongKinYiu/yolov9, installs CPU PyTorch + ONNX deps, and exports
# yolov9-${MODEL_SIZE} at ${IMG_SIZE} to ONNX. The runtime stage is alpine with
# nothing but /model.onnx — copied into the frigate-config PVC by the
# `seed-model` init container in services/frigate.tf.
#
# Frigate's ONNX detector ships no default model and does NOT auto-download on
# the ROCm path (frigate/detectors/plugins/onnx.py reads model.path with no
# fallback), so we produce one ourselves. The export mirrors Frigate's docs for
# self-built YOLOv9 models. Rebuild = bump these ARGs or change anything above
# the runtime stage; BuildKit's content-addressed hash retags + rolls the pod.
#
# MODEL_SIZE: c (full YOLOv9) — big accuracy jump over the iGPU-era `t`; the
#   R9700 (gfx1201) has ample headroom. Bump to `e` (extended) for max accuracy.
#   Converted weights exist for c and e at the v0.1 release. The runtime detector
#   runs this ONNX under ROCm 7.1.1 (MIGraphXExecutionProvider) — model is GPU-agnostic.
# IMG_SIZE: 640 — standard detection resolution; far better small/distant-object
#   recall than the old Coral 320.
ARG MODEL_SIZE=c
ARG IMG_SIZE=640

FROM python:3.11-slim AS build
# libglib2.0-0 -> libgthread-2.0.so.0 for opencv-python's cv2; libgl1 ->
# libGL.so.1; cmake/wget/git/ca-certs round out the YOLOv9 export toolchain.
RUN apt-get update \
    && apt-get install --no-install-recommends -y git cmake libgl1 libglib2.0-0 wget ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=ghcr.io/astral-sh/uv:0.10.4 /uv /bin/
# 7-day PyPI publish cooldown, applied inline to the PyPI installs below.
# Deliberately NOT a global ENV and NOT applied to the torch/torchvision line:
# those come from pytorch's first-party CPU index (--index-url .../whl/cpu),
# whose `+cpu` wheels don't expose a resolver-usable upload-time. Under
# --exclude-newer uv then treats the cp311/x86_64 wheels as unavailable and the
# resolve fails (no matching platform tag). The CPU index is a trusted
# first-party source, so it's exempt. Value threaded from
# var.pip_proxy_cooldown_value via the BuildKit build-arg.
ARG UV_EXCLUDE_NEWER="7 days"

WORKDIR /yolov9
RUN git clone --depth 1 https://github.com/WongKinYiu/yolov9.git .
# CPU-only torch first so YOLOv9's requirements.txt sees it satisfied and skips
# the ~3GB CUDA stack — export is CPU-bound, inference runs under ROCm at runtime.
#
# `env -u UV_EXCLUDE_NEWER`: this command must run with NO cooldown of any kind.
# `--index-url .../whl/cpu` makes the pytorch CPU index the SOLE source for the
# whole closure — torch AND its transitive deps. The torch `+cpu` wheels do carry
# `data-upload-time`, but the dep entries on that index (e.g. numpy) do NOT, and
# uv treats an undated distribution as UNAVAILABLE whenever exclude-newer is set
# at all (a far-future date won't rescue them). So we strip the env var for just
# this RUN — defeating both an inherited UV_EXCLUDE_NEWER and any stale BuildKit
# cache layer (the changed command string is a fresh cache key). The CPU index is
# a trusted first-party source, so exempting it is acceptable; the requirements
# .txt + onnx installs below resolve from PyPI (dated) and stay cooled.
RUN env -u UV_EXCLUDE_NEWER uv pip install --system --index-url https://download.pytorch.org/whl/cpu torch torchvision
RUN uv pip install --system --exclude-newer "${UV_EXCLUDE_NEWER}" -r requirements.txt
RUN uv pip install --system --exclude-newer "${UV_EXCLUDE_NEWER}" onnx==1.18.0 onnxruntime "onnx-simplifier==0.4.*" onnxscript

ARG MODEL_SIZE
ARG IMG_SIZE
ADD https://github.com/WongKinYiu/yolov9/releases/download/v0.1/yolov9-${MODEL_SIZE}-converted.pt yolov9-${MODEL_SIZE}.pt

# Newer torch refuses pickled checkpoints by default; YOLOv9's export.py calls
# torch.load without weights_only=False, so patch it (per Frigate's docs).
RUN sed -i "s/ckpt = torch.load(attempt_download(w), map_location='cpu')/ckpt = torch.load(attempt_download(w), map_location='cpu', weights_only=False)/g" models/experimental.py

RUN echo "export imgsz=${IMG_SIZE}" && uv run --no-project python3 export.py --weights ./yolov9-${MODEL_SIZE}.pt --imgsz ${IMG_SIZE} --simplify --include onnx

FROM alpine:3.23
ARG MODEL_SIZE
COPY --from=build /yolov9/yolov9-${MODEL_SIZE}.onnx /model.onnx
