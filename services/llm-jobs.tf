# Build + model-staging Jobs for the local llama-swap inference service.
#
#   1. llm_build           — rootless BuildKit Job that compiles the
#                            Vulkan/RADV llama.cpp + llama-swap image and pushes
#                            ${local.llm_image}. Rebuilds keyed off the Dockerfile
#                            hash + build_args (version bumps), so a steady-state
#                            apply is a no-op.
#   2. llm_model_download  — one-shot Job that fetches the GGUFs into the
#                            llm-models PVC. Idempotent (skip-if-present), named
#                            off a hash of the file list so it only re-runs when
#                            the list changes.

module "llm_build" {
  source = "./../templates/buildkit-job"

  name      = "llama-swap"
  image_ref = local.llm_image

  context_files = {
    "Dockerfile" = file("${path.module}/../data/images/llama-swap/Dockerfile")
  }

  # Authoritative version pins — bumping either retriggers the build hash.
  # Mirror the Dockerfile ARG defaults; re-verify against upstream releases:
  #   github.com/ggml-org/llama.cpp/releases  /  github.com/mostlygeek/llama-swap/releases
  build_args = {
    LLAMACPP_REF       = "b9297"
    LLAMA_SWAP_VERSION = "217"
  }

  # No source compile — just pulls upstream's prebuilt Vulkan binary +
  # llama-swap and repackages, so this is a light, fast build.
  resources = {
    requests = { cpu = "200m", memory = "512Mi" }
    limits   = { cpu = "2", memory = "2Gi" }
  }
  timeout = "15m"

  shared = local.buildkit_job_shared

  depends_on = [
    kubernetes_secret.builder_registry_pull_secret,
    kubernetes_config_map.builder_buildkitd_config,
  ]
}

# GGUF download script. Guarded so each file downloads once; the atomic
# .part → final rename means a Job killed mid-download never leaves a
# truncated file that the `-f` guard would wrongly skip. All repos are
# public (no HF token). Filenames verified against the repos' file lists —
# re-check on a quant/model change.
locals {
  llm_model_download_script = <<-EOT
    set -e
    cd /models
    # dl <repo> <src-file> [dest-file]   dest defaults to src; lets us
    # namespace a generically-named file (e.g. mmproj-F16.gguf) on disk.
    dl() {
      dest="$3"
      [ -z "$dest" ] && dest="$2"
      if [ -f "$dest" ]; then echo "skip $dest (present)"; return; fi
      echo "downloading $dest from $1/$2"
      # -C - resumes a prior partial ".part" by byte offset (HF CDN supports
      # range requests) instead of re-pulling gigabytes after an interruption.
      curl -fL -C - --retry 5 --retry-delay 5 -o "$dest.part" "https://huggingface.co/$1/resolve/main/$2"
      mv "$dest.part" "$dest"
    }
    dl unsloth/Qwen3.6-35B-A3B-GGUF               Qwen3.6-35B-A3B-UD-Q6_K.gguf
    dl unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF  Qwen3-Coder-30B-A3B-Instruct-Q6_K.gguf
    dl Qwen/Qwen3-4B-GGUF                         Qwen3-4B-Q8_0.gguf
    dl Qwen/Qwen3-1.7B-GGUF                       Qwen3-1.7B-Q8_0.gguf
    dl unsloth/gemma-4-31B-it-GGUF                gemma-4-31B-it-Q5_K_M.gguf
    dl unsloth/gemma-4-31B-it-GGUF                mmproj-F16.gguf               gemma-4-mmproj-F16.gguf
    # EXPERIMENTAL Qwen3-Coder-Next 80B-A3B (~49.6GB single file, root of the
    # repo — the UD-Q5/Q6 quants are sharded-in-folders, UD-Q4_K_XL is not).
    dl unsloth/Qwen3-Coder-Next-GGUF              Qwen3-Coder-Next-UD-Q4_K_XL.gguf
    echo "all models present"
  EOT
}

resource "kubernetes_job" "llm_model_download" {
  metadata {
    # Hash suffix = same file list → same name → no-op on re-apply; adding a
    # model changes the hash → fresh Job runs and skips already-present files.
    name      = "llm-model-download-${substr(sha256(local.llm_model_download_script), 0, 8)}"
    namespace = kubernetes_namespace.llm.metadata[0].name
  }

  spec {
    backoff_limit              = 3
    ttl_seconds_after_finished = 172800

    template {
      metadata {}
      spec {
        restart_policy = "OnFailure"

        # PVC is local-path on artemis — the Job must land there to write it.
        node_selector = { node = "artemis" }
        toleration {
          key      = "gpu"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }

        # No amd.com/gpu — pure I/O. Root so it can write the PVC dir.
        security_context {
          run_as_user = 0
        }

        container {
          name              = "download"
          image             = var.image_curl
          image_pull_policy = "Always"
          command           = ["sh", "-c", local.llm_model_download_script]

          volume_mount {
            name       = "models"
            mount_path = "/models"
          }

          resources {
            requests = { cpu = "200m", memory = "256Mi" }
            limits   = { cpu = "2", memory = "1Gi" }
          }
        }

        volume {
          name = "models"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.llm_models.metadata[0].name
          }
        }
      }
    }
  }

  # Don't block `terraform apply` on multi-GB downloads. The llm Deployment
  # depends_on this Job's creation, not its completion; first inference for a
  # given model waits until that GGUF finishes downloading.
  wait_for_completion = false
}
