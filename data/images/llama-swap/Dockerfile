# llama-swap + llama.cpp (Vulkan/RADV) for RDNA4 gfx1201 (2× R9700) on artemis.
#
# Deployment "Option 1" from docs/LLM.md: one llama-swap process spawns a
# llama-server per model on demand, both cards spanned via layer-split, one
# model resident at a time. Vulkan (RADV) backend — NOT ROCm/HIP — because on
# RDNA4 in 2026 Vulkan is faster (~183 vs ~150 tok/s decode on Qwen3-30B-A3B).
# The GPU is reached over the DRM render nodes the amd.com/gpu device plugin
# injects (services/amd-gpu-plugin.tf); no ROCm userspace is needed here.
#
# Two pieces, both "fat base + drop binaries on top":
#   1. Runtime driver — RDNA4/gfx1201 needs Mesa >= 25.2 (RADV). We base on
#      ubuntu:26.04 (LTS, ships Mesa 26.0.x) so the STOCK mesa-vulkan-drivers
#      already drive the R9700 — no PPA, no compile. (ubuntu:24.04's ~24.0 Mesa
#      predates RDNA4, which is why the prebuilt :vulkan images don't work here.)
#   2. Engine — upstream's PREBUILT llama.cpp Vulkan binary (shaders, incl. the
#      RDNA4 cooperative-matrix ones, are compiled by llama.cpp CI) + the
#      llama-swap proxy binary. No Vulkan SDK / glslc / source build.
#
# Versions are build_args so a bump folds into the BuildKit rebuild hash
# (services/llm-jobs.tf). Re-verify against upstream releases when bumping:
#   - LLAMACPP_REF       github.com/ggml-org/llama.cpp/releases  (the
#                        llama-<ref>-bin-ubuntu-vulkan-x64.tar.gz asset)
#   - LLAMA_SWAP_VERSION github.com/mostlygeek/llama-swap/releases
ARG LLAMACPP_REF=b9297
ARG LLAMA_SWAP_VERSION=217

FROM ubuntu:26.04
ARG LLAMACPP_REF
ARG LLAMA_SWAP_VERSION
ENV DEBIAN_FRONTEND=noninteractive

# Stock Mesa 26.0.x RADV (RDNA4 gfx1201 cooperative-matrix) from the base
# distro — no PPA. Plus the Vulkan loader the prebuilt binary links against and
# libgomp1 / libcurl4 for its OpenMP + model-pull support.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl \
      mesa-vulkan-drivers libvulkan1 vulkan-tools libgomp1 libcurl4 \
 && rm -rf /var/lib/apt/lists/*

# Prebuilt llama.cpp Vulkan binaries + the llama-swap proxy binary. The llama
# tarball is dynamically linked (libllama.so / libggml*.so), so copy the .so
# files alongside the binary and point the loader at them. find -based copy is
# robust to the archive's internal directory layout (build/bin vs bin).
RUN mkdir -p /tmp/llama \
 && curl -fsSL -o /tmp/llama.tgz \
      "https://github.com/ggml-org/llama.cpp/releases/download/${LLAMACPP_REF}/llama-${LLAMACPP_REF}-bin-ubuntu-vulkan-x64.tar.gz" \
 && tar -xzf /tmp/llama.tgz -C /tmp/llama \
 && bindir="$(dirname "$(find /tmp/llama -type f -name llama-server | head -1)")" \
 && cp -a "$bindir"/. /usr/local/bin/ \
 && find /tmp/llama \( -name 'lib*.so' -o -name 'lib*.so.*' \) -exec cp -a {} /usr/local/bin/ \; \
 && curl -fsSL -o /tmp/ls.tgz \
      "https://github.com/mostlygeek/llama-swap/releases/download/v${LLAMA_SWAP_VERSION}/llama-swap_${LLAMA_SWAP_VERSION}_linux_amd64.tar.gz" \
 && tar -xzf /tmp/ls.tgz -C /usr/local/bin llama-swap \
 && chmod +x /usr/local/bin/llama-server /usr/local/bin/llama-swap \
 && rm -rf /tmp/llama /tmp/llama.tgz /tmp/ls.tgz

# The llama .so files live next to the binary in /usr/local/bin.
ENV LD_LIBRARY_PATH=/usr/local/bin
# Force the RADV ICD (Mesa's AMD Vulkan driver) so the loader doesn't also
# pull in lvp_icd.json (lavapipe, software) and silently run on the CPU. NOTE
# the filename: Ubuntu 26.04's mesa ships `radeon_icd.json` (no `.x86_64`
# suffix — the older Debian naming was wrong and yielded "Found no drivers").
ENV VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/radeon_icd.json

EXPOSE 8080
ENTRYPOINT ["llama-swap"]
CMD ["-config", "/etc/llama-swap/config.yaml", "-listen", ":8080"]
