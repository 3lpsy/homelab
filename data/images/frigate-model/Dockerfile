# syntax=docker/dockerfile:1.4
#
# Builds a single-file artifact image for the Frigate ONNX detector. The
# build stage clones WongKinYiu/yolov9, installs PyTorch + ONNX deps, and
# exports yolov9-t at 320x320 to ONNX. The runtime stage is alpine with
# nothing but /model.onnx and /bin/cp — used as a Frigate init container
# that copies the model into the frigate-config PVC.
#
# Frigate's ONNX detector ships no default model (frigate/detectors/plugins/
# onnx.py reads model.path with no fallback download), so we have to
# produce one ourselves. The export command mirrors what Frigate's docs
# recommend for self-built YOLOv9 models. Rebuild = bump these ARG values
# or change anything above the runtime stage; BuildKit's content-addressed
# Dockerfile hash will retag the image and roll the Frigate pod via the
# existing init-container image reference.

ARG MODEL_SIZE=t
ARG IMG_SIZE=320

FROM python:3.11-slim AS build
# libglib2.0-0 provides libgthread-2.0.so.0 for opencv-python's cv2;
# libgl1 covers libGL.so.1; cmake/wget/git/ca-certs round out the
# YOLOv9 export toolchain.
RUN apt-get update \
    && apt-get install --no-install-recommends -y git cmake libgl1 libglib2.0-0 wget ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=ghcr.io/astral-sh/uv:0.10.4 /uv /bin/

WORKDIR /yolov9
RUN git clone --depth 1 https://github.com/WongKinYiu/yolov9.git .
# CPU-only torch first so YOLOv9's requirements.txt sees it satisfied and
# skips pulling the ~3GB CUDA stack (cublas/cudnn/triton/etc) — Frigate
# runs inference under ROCm at runtime, not CUDA, and the export step
# itself is CPU-bound.
RUN uv pip install --system --index-url https://download.pytorch.org/whl/cpu torch torchvision
RUN uv pip install --system -r requirements.txt
RUN uv pip install --system onnx==1.18.0 onnxruntime "onnx-simplifier==0.4.*" onnxscript

ARG MODEL_SIZE
ARG IMG_SIZE
ADD https://github.com/WongKinYiu/yolov9/releases/download/v0.1/yolov9-${MODEL_SIZE}-converted.pt yolov9-${MODEL_SIZE}.pt

# Newer torch refuses pickled checkpoints by default; YOLOv9's export.py
# calls torch.load without weights_only=False, so we patch it. Same shim
# Frigate's own docs recommend.
RUN sed -i "s/ckpt = torch.load(attempt_download(w), map_location='cpu')/ckpt = torch.load(attempt_download(w), map_location='cpu', weights_only=False)/g" models/experimental.py

RUN python3 export.py --weights ./yolov9-${MODEL_SIZE}.pt --imgsz ${IMG_SIZE} --simplify --include onnx

FROM alpine:3.20
ARG MODEL_SIZE
COPY --from=build /yolov9/yolov9-${MODEL_SIZE}.onnx /model.onnx
