# Remote opencode `web` server. Single pod = opencode + nginx +
# oauth2-proxy + tailscale sidecars. Browser users + the desktop
# `opencode attach` CLI both hit the same backend on
# https://opencode.<hs>.<magic>; oauth2-proxy gates the browser flow with
# an OIDC cookie and validates `Authorization: Bearer <jwt>` on the CLI
# path (OAUTH2_PROXY_SKIP_JWT_BEARER_TOKENS=true). Per-user access is
# enforced upstream by the Zitadel project's has_project_check=true —
# only granted users can mint tokens for this audience.
#
# Git: opencode pushes/pulls to Forgejo (services/git.tf) over SSH using
# a TF-generated ed25519 key (tls_private_key.opencode_git_ssh below),
# materialized into /home/user/.ssh by an init container. Remotes look like
# `ssh://git@git.<hs>.<magic>/<owner>/<repo>.git`; ~/.ssh/config remaps
# the port to 2222 (rootless Forgejo container).

locals {
  opencode_fqdn  = "${var.opencode_domain}.${local.magic_fqdn_suffix}"
  opencode_image = "${local.thunderbolt_registry}/opencode:latest"

  # Forgejo's tailnet FQDN. Opencode pins it to the in-cluster Service
  # ClusterIP via host_aliases (no Tailscale egress sidecar per
  # feedback_no_egress_only_ts_sidecars).
  opencode_git_fqdn = "${var.git_domain}.${local.magic_fqdn_suffix}"

  # npm (Verdaccio) + crates caching proxies, also in the registry-proxy ns.
  # In-pod npm/cargo route through these (7-day cooldown) instead of npmjs /
  # crates.io directly. Pinned to the Service ClusterIP via host_aliases below
  # so the FQDN resolves in-cluster while still matching the nginx cert SAN.
  opencode_npm_proxy_fqdn    = "${var.npm_domain}.${local.magic_fqdn_suffix}"
  opencode_crates_proxy_fqdn = "${var.crates_domain}.${local.magic_fqdn_suffix}"

  # MCP block in opencode.json — one entry per backend behind the shared
  # gateway. Adding a new MCP server (entry in local.mcp_backend_services)
  # auto-extends opencode's tool surface on next apply.
  #
  # Most MCPs ship `enabled = false` by default — each enabled MCP's tool
  # schema costs ~1-3k tokens per request, and the full set adds up to ~15k+
  # tokens of overhead on every turn (billed at $0.20/M for our default coding
  # model = real money on long sessions). The exceptions (default ON) are
  # `sequential-thinking`, `git`, and `memory` — cheap/high-value enough to
  # justify their always-on schema cost. The rest are opt-in per session via
  # opencode's `/mcp` UI; since OPENCODE_CONFIG is a read-only ConfigMap, a
  # durable enable is a config edit here + apply (Reloader rolls the pod).
  opencode_mcp_block = merge(
    {
      for name, _ in local.mcp_backend_services :
      # Strip the leading "mcp-" so opencode addresses the tool by short
      # name (e.g. `searxng`, `time`) — matches the user's existing config.
      replace(name, "mcp-", "") => {
        type = "remote"
        url  = "https://${local.mcp_shared_fqdn}/${name}/?api_key={env:MCP_API_KEY}"
        # Only searxng is default-on among the remotes — web search is high
        # value for the coding workflow. The rest (incl. memory) stay off:
        # each adds a per-turn schema tax to context, and on the A3B primary
        # memory's recalls inject graph nodes that work against the context
        # budget. Toggle any on per session when its value beats that cost.
        enabled = contains(["mcp-searxng"], name)
      }
    },
    {
      # Anthropic-official structured-reasoning MCP. npm-distributed, runs
      # in-process via bun (no extra container / network egress). Schema
      # cost ~0.5k tokens. Default off — toggle on for hard reasoning tasks
      # where the small model benefits from explicit step-by-step
      # scaffolding. https://github.com/modelcontextprotocol/servers
      "sequential-thinking" = {
        type    = "local"
        command = ["bunx", "@modelcontextprotocol/server-sequential-thinking"]
        # Default off: redundant on the thinking 35b primary (native <think>
        # channel already reasons step-by-step, and its external thoughts
        # would persist in context un-stripped). Toggle on for the
        # non-thinking coder model on hard reasoning tasks.
        enabled = false
      }
      # Anthropic-official git server. 12 structured tools (status, diff,
      # commit, add, reset, log, branch, checkout, show, ...). Local-only
      # — works against the in-pod working tree; remotes (now Forgejo via
      # ssh://git@git.<magic>/<owner>/<repo>.git) are pushed/pulled via the
      # bare git CLI using the ed25519 key in /home/user/.ssh, not through this
      # MCP. uvx is in the image via layer 3 (uv installer). Schema cost
      # ~2k tokens; the only MCP default-on — structured git is high-value for
      # the coding workflow and worth the per-turn cost.
      # https://github.com/modelcontextprotocol/servers/tree/main/src/git
      "git" = {
        type    = "local"
        command = ["uvx", "mcp-server-git"]
        enabled = true
      }
    },
  )

  # Models block derived from var.llm_models so the LiteLLM alias list is
  # the single source of truth — adding or repricing a model in one place
  # propagates to opencode on the next apply.
  #
  # Cost conversion: var.llm_models stores `*_cost_per_token` in dollars
  # per single token; opencode's `cost.{input,output}` is dollars per 1M
  # tokens, so multiply by 1e6.
  #
  # `limit = { context, output }` is required: without an explicit
  # `limit.output`, opencode hardcodes max_tokens=32000 in the request
  # body for custom providers (sst/opencode#1735, #20078), which clamps
  # the real model ceiling and truncates long reasoning mid-stream.
  # opencode's schema demands BOTH `context` and `output` when `limit`
  # is present, so both must come from var.llm_models.
  #
  # `options` carries free-form per-model request params, forwarded by
  # opencode's AI SDK provider directly into the request body. Used for
  # reasoning-disable workarounds against the vLLM tool-call parser bug
  # (vllm#22578, #24076) that surfaces on DeepInfra for reasoning models.
  # Source of truth is var.llm_models.<alias>.opencode_options_json
  # (JSON-encoded so HCL's type system can map heterogeneous shapes
  # across entries; decoded here at render time).
  opencode_models = {
    for alias, cfg in var.llm_models : alias => merge(
      {
        # %.4g — 4 significant digits, no trailing zeros. Avoids the IEEE
        # 754 noise that bare %g surfaces for values like 3e-8 * 1e6 =
        # 0.030000000000000003.
        name = format(
          "%s ($%s/$%s/1M)",
          alias,
          cfg.input_cost_per_token == null ? "?" : format("%.4g", cfg.input_cost_per_token * 1000000),
          cfg.output_cost_per_token == null ? "?" : format("%.4g", cfg.output_cost_per_token * 1000000),
        )
      },
      cfg.input_cost_per_token == null && cfg.output_cost_per_token == null ? {} : {
        cost = merge(
          cfg.input_cost_per_token == null ? {} : { input = cfg.input_cost_per_token * 1000000 },
          cfg.output_cost_per_token == null ? {} : { output = cfg.output_cost_per_token * 1000000 },
        )
      },
      cfg.context_window == null || cfg.max_tokens == null ? {} : {
        limit = {
          context = cfg.context_window
          output  = cfg.max_tokens
        }
      },
      cfg.opencode_options_json == null ? {} : {
        options = jsondecode(cfg.opencode_options_json)
      },
    )
  }
}

resource "kubernetes_service_account" "opencode" {
  metadata {
    name      = "opencode"
    namespace = kubernetes_namespace.opencode.metadata[0].name
  }
  automount_service_account_token = false
}

# Pull-secret for the in-cluster registry. opencode image is a custom
# BuildKit build (data/images/opencode/Dockerfile) pushed to the local
# registry by services/opencode-jobs.tf.
resource "kubernetes_secret" "opencode_registry_pull_secret" {
  metadata {
    name      = "registry-pull-secret"
    namespace = kubernetes_namespace.opencode.metadata[0].name
  }
  type = "kubernetes.io/dockerconfigjson"
  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "${local.thunderbolt_registry}" = {
          username = "internal"
          password = random_password.registry_user_passwords["internal"].result
          auth     = base64encode("internal:${random_password.registry_user_passwords["internal"].result}")
        }
      }
    })
  }
}

# Cookie key for the oauth2-proxy sidecar. 32 alphanumeric chars satisfies
# oauth2-proxy's 32-byte case and avoids URL-encoding edge cases when the
# value is exposed via OAUTH2_PROXY_COOKIE_SECRET. Rotate with:
#   ./terraform.sh services apply -replace=random_password.opencode_oauth2_cookie
resource "random_password" "opencode_oauth2_cookie" {
  length  = 32
  special = false
}

# ─── Zitadel project + OIDC application + per-user grant ────────────────────
#
# Per memory feedback_zitadel_one_project_per_service, opencode declares
# its own Zitadel project. has_project_check=true so Zitadel itself
# refuses to mint a token (cookie OR bearer) for any user who hasn't
# been granted on this project — that's the per-user gate
# (project_grafana_oidc_authz_pending: opencode does NOT replicate the
# loose Grafana pattern; access is restricted to the personal user only).
resource "zitadel_project" "opencode" {
  name   = "opencode"
  org_id = data.zitadel_organizations.homelab.ids[0]

  project_role_assertion   = false
  project_role_check       = false
  has_project_check        = true
  private_labeling_setting = "PRIVATE_LABELING_SETTING_UNSPECIFIED"
}

resource "zitadel_application_oidc" "opencode" {
  name       = "opencode"
  org_id     = data.zitadel_organizations.homelab.ids[0]
  project_id = zitadel_project.opencode.id

  redirect_uris = [
    "https://${local.opencode_fqdn}/oauth2/callback",
    # Loopback redirect for the desktop CLI's OIDC code flow. RFC 8252
    # §7.3 designates loopback IPs as a redirect channel for native/CLI
    # clients. Two ports registered so either `oauth2c` (default 9876)
    # or a custom helper script (8765) works without further edits.
    "http://127.0.0.1:9876/callback",
    "http://127.0.0.1:8765/cb",
  ]
  post_logout_redirect_uris = ["https://${local.opencode_fqdn}/"]

  response_types   = ["OIDC_RESPONSE_TYPE_CODE"]
  grant_types      = ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE", "OIDC_GRANT_TYPE_REFRESH_TOKEN"]
  app_type         = "OIDC_APP_TYPE_WEB"
  auth_method_type = "OIDC_AUTH_METHOD_TYPE_BASIC"
  dev_mode         = false

  # JWT access tokens (default is opaque BEARER). Lets oauth2-proxy
  # validate via JWKS for any bearer path (opencode CLI, git over HTTPS),
  # without an introspection round-trip back to Zitadel. id_tokens are
  # always JWT; this change makes access_tokens match. Browser cookie flow
  # is unaffected — oauth2-proxy's session cookie doesn't care what format
  # the access_token has, it just stores+refreshes it.
  access_token_type = "OIDC_TOKEN_TYPE_JWT"
}

# Personal user is the only granted identity. has_project_check above
# refuses token issuance to anyone else, so this single grant is the
# whole authz surface.
resource "zitadel_user_grant" "opencode_personal_user" {
  org_id     = data.zitadel_organizations.homelab.ids[0]
  user_id    = zitadel_human_user.personal.id
  project_id = zitadel_project.opencode.id
  role_keys  = []
}

module "opencode_tailscale" {
  source = "../templates/tailscale-ingress"

  name                 = "opencode"
  namespace            = kubernetes_namespace.opencode.metadata[0].name
  service_account_name = kubernetes_service_account.opencode.metadata[0].name
  tailnet_user_id      = data.terraform_remote_state.homelab.outputs.tailnet_user_map.opencode_server_user
}

# Opencode's git-side SSH key. TF-generated ed25519 (no passphrase) — the
# private half goes to Vault → CSI → /mnt/secrets/git_ssh_priv → copied into
# /home/user/.ssh/id_ed25519 by an init container. The public half lives as a
# ConfigMap in the `git` namespace (kubernetes_config_map.git_opencode_pubkey
# in services/git.tf) and is consumed by Forgejo's bootstrap Job to
# register it on the local `opencode` user. Rotate via
# `terraform apply -replace=tls_private_key.opencode_git_ssh` — both halves
# regenerate atomically; Forgejo bootstrap re-runs on the new pub-key hash.
resource "tls_private_key" "opencode_git_ssh" {
  algorithm = "ED25519"
}

# Forgejo API token for opencode's `fj` CLI (write:repository,write:issue,
# scoped to the RESTRICTED opencode user). The token is RUNTIME-generated by
# Forgejo (it can't be a TF/Vault value), so TF only owns this Secret as an empty
# placeholder; the git bootstrap Job mints the token and PATCHes it into `data`
# here (RBAC: kubernetes_role.opencode_forgejo_token_writer in this ns, bound to
# the `git` SA the bootstrap Job runs as). ignore_changes[data] keeps TF from clobbering the
# bootstrap-written value on subsequent applies. opencode mounts it via the
# FORGEJO_TOKEN env (optional) + Reloader rolls opencode when it's patched.
# Rotate: delete the `opencode-fj` token in Forgejo + clear this Secret's data,
# then re-run the bootstrap.
resource "kubernetes_secret" "opencode_forgejo_token" {
  metadata {
    name      = "opencode-forgejo-token"
    namespace = kubernetes_namespace.opencode.metadata[0].name
  }
  data = {
    token = ""
  }
  lifecycle {
    ignore_changes = [data]
  }
}

# Least-privilege RBAC: the Forgejo bootstrap Job (in the `git` ns) may get/patch
# ONLY the opencode-forgejo-token Secret in this ns — nothing else. That's how it
# delivers the minted token without the bootstrap pod holding broad API rights.
resource "kubernetes_role" "opencode_forgejo_token_writer" {
  metadata {
    name      = "opencode-forgejo-token-writer"
    namespace = kubernetes_namespace.opencode.metadata[0].name
  }
  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = [kubernetes_secret.opencode_forgejo_token.metadata[0].name]
    verbs          = ["get", "patch", "update"]
  }
}

resource "kubernetes_role_binding" "opencode_forgejo_token_writer" {
  metadata {
    name      = "opencode-forgejo-token-writer"
    namespace = kubernetes_namespace.opencode.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.opencode_forgejo_token_writer.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.git.metadata[0].name
    namespace = kubernetes_namespace.git.metadata[0].name
  }
}

module "opencode_tls_vault" {
  source = "../templates/service-tls-vault"

  service_name         = "opencode"
  namespace            = kubernetes_namespace.opencode.metadata[0].name
  service_account_name = kubernetes_service_account.opencode.metadata[0].name

  acme_account_key_pem  = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  tls_domain            = local.opencode_fqdn
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  vault_kv_mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path

  config_secrets = {
    # opencode pod's outbound LiteLLM key. LITELLM_API_KEY env (matches
    # opencode.json's `{env:LITELLM_API_KEY}` interpolation).
    litellm_api_key = lookup(var.litellm_user_keys, "opencode", "")

    # Bearer token validated by every MCP backend behind the shared
    # gateway. Reuses random_password.mcp_api_keys["opencode"] from
    # services/mcp-secrets.tf — opencode is already in
    # var.mcp_api_key_users default.
    mcp_api_key = random_password.mcp_api_keys["opencode"].result

    # OIDC client + cookie key for the oauth2-proxy sidecar.
    oidc_client_id       = zitadel_application_oidc.opencode.client_id
    oidc_client_secret   = zitadel_application_oidc.opencode.client_secret
    oauth2_cookie_secret = random_password.opencode_oauth2_cookie.result

    # Forgejo SSH key. Surfaces as /mnt/secrets/git_ssh_priv /
    # /mnt/secrets/git_ssh_pub; an init container copies into ~/.ssh and
    # chmods 0600 (sshd strictly enforces priv key perms). OpenSSH PEM
    # parser requires a trailing newline after -----END … KEY-----, so
    # do NOT trimspace() the private key — libcrypto rejects it otherwise.
    git_ssh_priv = tls_private_key.opencode_git_ssh.private_key_openssh
    git_ssh_pub  = trimspace(tls_private_key.opencode_git_ssh.public_key_openssh)
  }

  providers = { acme = acme }
}

# opencode JSON config rendered as a ConfigMap. Mounted RO and pointed at
# via OPENCODE_CONFIG env. Mirrors the user's local config except:
#   - LiteLLM baseURL parameterised against var.litellm_domain
#   - MCP block iterates local.mcp_backend_services so adding a new MCP
#     server auto-extends opencode's tool surface
#   - permission `*` is `allow` (not `ask`) — `ask` deadlocks the
#     headless server (opencode GH #14473, #16367)
#   - $schema dropped; opencode tolerates absence.
resource "kubernetes_config_map" "opencode_config" {
  metadata {
    name      = "opencode-config"
    namespace = kubernetes_namespace.opencode.metadata[0].name
  }
  data = {
    "opencode.json" = jsonencode({
      "$schema"         = "https://opencode.ai/config.json"
      enabled_providers = ["litellm"]
      mcp               = local.opencode_mcp_block
      # Image is BuildKit-built; runtime self-update would diverge from
      # the registry tag and not survive the next pod restart anyway.
      autoupdate = false
      # Kill the conversation-publish path to opencode.ai's sharing
      # service entirely — UI button gone, no accidental publishes.
      share = "disabled"
      # File-change snapshots add latency without value inside a single-
      # user pod — git is the snapshot mechanism here.
      snapshot = false
      # small_model intentionally NOT set: with it omitted, opencode routes
      # title generation, summaries, and compaction to the primary `model`
      # below instead of a cheap alias. Rationale: the primary is a Qwen3
      # MoE (A3B = ~3B active params/token), so these tiny utility tasks run
      # at ~3B-dense compute on an already-resident model — near-free — while
      # eliminating the small<->big llama-swap thrash the 4b caused (every
      # title evicted the big model, forcing a ~28GB reload). The 4b also
      # skipped the tool calls agentic work needs (see `explore` below).
      # CAVEAT: best paired with a NON-THINKING primary (e.g. coder-30b). If
      # the primary is the thinking 35b (--reasoning-budget -1), titles +
      # compaction will burn reasoning tokens on trivial tasks — slower and
      # wasteful. Re-add small_model (pointing at a budget-0 alias) if so.

      # `instructions` is opencode's additive-on-top mechanism. Opencode
      # already auto-loads:
      #   1. Local AGENTS.md / CLAUDE.md via parent-walk from cwd
      #      (first match wins, stops at first hit)
      #   2. Global ~/.config/opencode/AGENTS.md (always loads —
      #      that's where opencode-rust-agents CM mounts)
      #   3. Global ~/.claude/CLAUDE.md (always loads unless disabled)
      # All three categories combine into context. We don't list any
      # explicit instructions here — categories 1 and 2 cover both
      # repo-specific and pod-wide guidance with no overlap.
      instructions = []

      # 128k-context GLM-Air benefits from leaving more head-room when
      # opencode auto-compacts. `reserved` is tokens held back from the
      # context window for the new prompt + tools. Default is a few
      # thousand; bumping to 8192 keeps a turn's worth of headroom even
      # late in a long session.
      compaction = {
        auto     = true
        reserved = 8192
      }

      permission = {
        "*" = "allow"
        read = {
          "*.env"   = "deny"
          "*.env.*" = "deny"
        }
        skill = {
          caveman               = "allow"
          "rust-*"              = "allow"
          "commit-conventional" = "allow"
          "skill-creator"       = "allow"
        }
      }

      provider = {
        litellm = {
          npm  = "@ai-sdk/openai-compatible"
          name = "LiteLLM"
          options = {
            baseURL = "https://${var.litellm_domain}.${local.magic_fqdn_suffix}/v1"
            apiKey  = "{env:LITELLM_API_KEY}"
          }
          models = local.opencode_models
        }
      }
      model = "litellm/coding-qwen-3.6-35b-a3b"

      # ─── Tiered subagents ──────────────────────────────────────────────
      # Primary stays on the user's main model (above). Subagents offload
      # specific shapes of work to cheaper or stronger models so the main
      # context window doesn't carry every read or review turn.
      #
      # Model routing:
      #   - explore     → inherits primary (no model pin; needs reliable
      #                   tool-calling, which the dropped 4b lacked)
      #   - rust-reviewer → primary coding model (strongest for code review)
      #   - commit-msg  → inherits primary (no model pin; one-shot, near-free)
      # Subagents still isolate context + permissions even on the same model.
      agent = {
        explore = {
          mode        = "subagent"
          description = "Read-only file/code exploration. Returns short summaries with file:line refs. Use this before editing when you need to locate something across the workspace."
          # No `model`: inherits the primary. The old 4b pin was dropped —
          # small models skip the tool calls explore depends on; the MoE
          # primary navigates the workspace reliably at ~3B-active per-token
          # cost. See the small_model note above.
          temperature = 0.2
          permission = {
            edit  = "deny"
            write = "deny"
            bash  = "deny"
          }
        }
        "rust-reviewer" = {
          mode        = "subagent"
          description = "Reviews Rust diffs for idioms, clippy violations, error-handling hygiene. Read-only — returns findings, caller applies fixes."
          # Strongest local model (the headline Qwen3.6-35B-A3B) now that the
          # flagship-gpt-oss-120b DeepInfra tier is retired (docs/LLM.md).
          model       = "litellm/coding-qwen-3.6-35b-a3b"
          temperature = 0.2
          permission = {
            edit  = "deny"
            write = "deny"
            bash = {
              "cargo clippy*" = "allow"
              "cargo fmt*"    = "allow"
              "cargo check*"  = "allow"
              "cargo udeps*"  = "allow"
              "cargo audit*"  = "allow"
              "*"             = "deny"
            }
          }
        }
        "commit-msg" = {
          mode        = "subagent"
          description = "Reads the staged diff and returns a single Conventional Commit message. Never edits files, never runs git commit."
          # No `model`: inherits the primary (4b pin dropped with small_model
          # — see note above). One-shot task, near-free on the resident MoE.
          temperature = 0.1
          permission = {
            edit  = "deny"
            write = "deny"
            bash = {
              "git diff*"   = "allow"
              "git status*" = "allow"
              "git log*"    = "allow"
              "*"           = "deny"
            }
          }
        }
      }

      # ─── Custom slash commands ─────────────────────────────────────────
      # Thin shell wrappers. The `!` substitution runs the command at
      # send-time and substitutes the output into the prompt; the agent
      # then reasons over the captured output. `subtask = true` forces
      # the named `agent` to handle the turn as a subtask so the
      # main-loop context isn't polluted with raw shell output.
      command = {
        clippy = {
          template    = "Clippy on the workspace returned:\n\n!`cargo clippy --workspace --all-targets -- -D warnings 2>&1`\n\nDiagnose findings and propose fixes — do not edit files until I confirm."
          description = "cargo clippy --workspace -D warnings → rust-reviewer"
          agent       = "rust-reviewer"
          subtask     = true
        }
        fmt = {
          template    = "Running rustfmt across the workspace:\n\n!`cargo fmt --all 2>&1`\n\nReport any files that changed; otherwise say `clean`."
          description = "cargo fmt --all"
        }
        expand = {
          template    = "Macro expansion for $ARGUMENTS:\n\n!`cargo +nightly expand $ARGUMENTS 2>&1 | head -200`"
          description = "cargo expand <args> (e.g. `--package mycrate --lib path::to::module`)"
        }
        udeps = {
          template    = "Unused dependency scan:\n\n!`cargo +nightly udeps --workspace 2>&1`\n\nFor each finding, verify it isn't feature-gated before proposing removal."
          description = "cargo +nightly udeps --workspace → rust-reviewer"
          agent       = "rust-reviewer"
          subtask     = true
        }
        audit = {
          template    = "Security advisory scan against the resolved Cargo.lock:\n\n!`cargo audit 2>&1`\n\nFor each advisory, propose a direct bump or a [patch.crates-io] override."
          description = "cargo audit → rust-reviewer"
          agent       = "rust-reviewer"
          subtask     = true
        }
        commit = {
          template    = "Staged diff for the next commit:\n\n!`git diff --staged`\n\nReturn a single Conventional Commit message (subject ≤50 chars, body only if the 'why' isn't obvious from the diff). Output the message and nothing else."
          description = "Write a Conventional Commit for the staged diff → commit-msg"
          agent       = "commit-msg"
          subtask     = true
        }
      }

      # ─── LSP tuning for rust-analyzer ──────────────────────────────────
      # Default rust-analyzer init has procMacro disabled, uses `cargo
      # check` instead of `clippy`, and shares the workspace `target/`
      # with opencode's own cargo invocations — small-model footguns:
      #   - opaque derive macros (procMacro off)
      #   - weaker lint signal (no clippy)
      #   - `target/` lock contention with /clippy etc
      # All three are fixed by overriding the rust-analyzer init options.
      # Pedantic-on with missing_errors_doc allowed so the broad lint
      # sweep doesn't drown context in docstring nags.
      lsp = {
        rust = {
          command    = ["rust-analyzer"]
          extensions = [".rs"]
          initialization = {
            cargo = {
              targetDir = "target/rust-analyzer"
            }
            procMacro = {
              enable = true
            }
            check = {
              command = "clippy"
              extraArgs = [
                "--",
                "-W", "clippy::pedantic",
                "-A", "clippy::missing_errors_doc",
              ]
            }
            diagnostics = {
              experimental = { enable = true }
            }
          }
        }
      }
    })
  }
}

resource "kubernetes_config_map" "opencode_git_script" {
  metadata {
    name      = "opencode-git-script"
    namespace = kubernetes_namespace.opencode.metadata[0].name
  }
  data = {
    "configure-git-ssh.sh" = file("${path.module}/../data/opencode/configure-git-ssh.sh")
  }
}

resource "kubernetes_config_map" "opencode_nginx_config" {
  metadata {
    name      = "opencode-nginx-config"
    namespace = kubernetes_namespace.opencode.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/opencode.nginx.conf.tpl", {
      server_domain       = local.opencode_fqdn
      nginx_logging_block = local.nginx_logging_blocks["opencode"]
    })
  }
}

# npm + cargo client config pointing both at the in-cluster cooldown proxies
# (npm Verdaccio + crates chilled-crates, 7-day gate) instead of npmjs /
# crates.io directly. Mounted read-only via subPath into both the `user`
# (uid 1001, HOME=/home/user) and `root` (opkssh SSH, HOME=/root) accounts; the
# cargo config lands in the SHARED CARGO_HOME (/usr/local/cargo, set image-wide
# in the Dockerfile §1b + re-exported in /etc/bash.bashrc), so one file covers
# both users. Rendered from the npm/crates domain vars (same source of truth as
# the host_aliases + ACLs). NOT baked into the image so the registry can move
# without an image rebuild. The proxies present public ACME (magic-domain)
# certs, so the pod's stock ca-certificates validate them — no strict-ssl off.
resource "kubernetes_config_map" "opencode_pkg_proxy_config" {
  metadata {
    name      = "opencode-pkg-proxy-config"
    namespace = kubernetes_namespace.opencode.metadata[0].name
  }
  data = {
    "npmrc" = "registry=https://${local.opencode_npm_proxy_fqdn}/\n"

    # Source replacement: every crates.io index lookup + crate download routes
    # through the proxy (which enforces the 7-day cooldown). chilled-crates is a
    # transparent crates.io mirror, so checksums still match. Build-speed tuning
    # (mold/cranelift/profiles) lives PER-PROJECT in each repo's .cargo/config.toml,
    # not here — this global config stays minimal so it never fights a project's
    # own settings. The tools themselves are baked in the image (Dockerfile §2c-2f).
    "cargo-config.toml" = <<-EOT
      [source.crates-io]
      replace-with = "chilled-crates"

      [registries.chilled-crates]
      index = "sparse+https://${local.opencode_crates_proxy_fqdn}/index/"
    EOT

    # uv (Python) publish-age cooldown — the PyPI analogue of the npm/crates
    # 7-day gate. Mounted at /etc/uv/uv.toml (system-level: read by every uv
    # invocation, any user, any cwd — the fallback when the env var isn't set,
    # e.g. non-interactive calls). exclude-newer takes a rolling duration that uv
    # resolves against "now" even from a config file, so this stays a true 7-day
    # window. Env (UV_EXCLUDE_NEWER in /etc/bash.bashrc) still wins for shells.
    "uv.toml" = "exclude-newer = \"${var.pip_proxy_cooldown_value}\"\n"
  }
}

# State lives here: sessions, conversation history, MCP OAuth tokens,
# and provider sdks (`@ai-sdk/openai-compatible` and friends are pulled
# from npm on first `opencode web` boot and persist under
# ~/.local/share/opencode). Lifecycle prevent_destroy: losing this PVC
# loses every saved chat. Resize via var.opencode_storage_size + manual
# kubectl edit if a larger volume is needed.
resource "kubernetes_persistent_volume_claim" "opencode_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "opencode-data"
    namespace = kubernetes_namespace.opencode.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = var.opencode_storage_size
      }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_deployment" "opencode" {
  metadata {
    name      = "opencode"
    namespace = kubernetes_namespace.opencode.metadata[0].name
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "opencode" }
    }

    template {
      metadata {
        labels = { app = "opencode" }
        annotations = {
          "opencode-config-hash"                = sha1(kubernetes_config_map.opencode_config.data["opencode.json"])
          "opencode-skills-hash"                = sha1(jsonencode(kubernetes_config_map.opencode_skills.data))
          "opencode-rust-agents-hash"           = sha1(kubernetes_config_map.opencode_rust_agents.data["AGENTS.md"])
          "git-script-hash"                     = sha1(kubernetes_config_map.opencode_git_script.data["configure-git-ssh.sh"])
          "nginx-config-hash"                   = sha1(kubernetes_config_map.opencode_nginx_config.data["nginx.conf"])
          "opk-config-hash"                     = sha1(jsonencode(kubernetes_config_map.opencode_opk.data))
          "pkg-proxy-config-hash"               = sha1(jsonencode(kubernetes_config_map.opencode_pkg_proxy_config.data))
          "secret.reloader.stakater.com/reload" = "${module.opencode_tls_vault.config_secret_name},${module.opencode_tls_vault.tls_secret_name},${kubernetes_secret.opencode_forgejo_token.metadata[0].name}"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.opencode.metadata[0].name

        # Pinned to the artemis GPU node (Phase-4 migration) — co-located with
        # builder + litellm so agent loops, image builds, and LLM calls stay
        # intra-node. node_selector pulls it onto artemis; the toleration clears
        # the gpu=true:NoSchedule taint. The opencode-data PVC (sessions +
        # /home/user/working repos) is re-provisioned on artemis and restored from a
        # node-to-node tar copy (local-path PVs are node-bound). See
        # docs/CLUSTER.md.
        node_selector = { node = "artemis" }
        toleration {
          key      = "gpu"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }

        image_pull_secrets {
          name = kubernetes_secret.opencode_registry_pull_secret.metadata[0].name
        }

        # In-cluster pinning per feedback_no_egress_only_ts_sidecars: each
        # tailnet FQDN this pod talks to is mapped to the destination
        # Service ClusterIP so SNI + Let's Encrypt cert validation work
        # without a Tailscale egress sidecar.
        host_aliases {
          ip        = data.terraform_remote_state.vault_conf.outputs.zitadel_cluster_ip
          hostnames = ["${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${local.magic_fqdn_suffix}"]
        }
        host_aliases {
          ip        = kubernetes_service.litellm.spec[0].cluster_ip
          hostnames = ["${var.litellm_domain}.${local.magic_fqdn_suffix}"]
        }
        host_aliases {
          ip        = kubernetes_service.mcp_shared.spec[0].cluster_ip
          hostnames = [local.mcp_shared_fqdn]
        }
        # Forgejo (services/git.tf). Reachable in-cluster via the git
        # Service ClusterIP; opencode uses
        # `ssh://git@${local.opencode_git_fqdn}/<owner>/<repo>.git` with
        # ~/.ssh/config remapping Port → 2222 (the rootless container can't
        # bind <1024).
        host_aliases {
          ip        = kubernetes_service.git.spec[0].cluster_ip
          hostnames = [local.opencode_git_fqdn]
        }
        # npm + crates cooldown proxies for the agent's own package installs
        # (it runs npm/cargo on the repos in /home/user/working). FQDN→ClusterIP
        # so TLS SNI matches the proxy nginx cert SAN; egress opened by
        # opencode_to_registry_proxy in opencode-network.tf.
        host_aliases {
          ip        = kubernetes_service.npm.spec[0].cluster_ip
          hostnames = [local.opencode_npm_proxy_fqdn]
        }
        host_aliases {
          ip        = kubernetes_service.crates.spec[0].cluster_ip
          hostnames = [local.opencode_crates_proxy_fqdn]
        }

        # Block until the TLS cert lands in /mnt/secrets so nginx doesn't
        # crashloop on missing certs at boot.
        init_container {
          name              = "wait-for-secrets"
          image             = var.image_busybox
          image_pull_policy = "Always"
          command = [
            "sh", "-c",
            templatefile("${path.module}/../data/scripts/wait-for-secrets.sh.tpl", {
              secret_file = "tls_crt"
            })
          ]
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # Materialize the Forgejo SSH key from CSI into /home/user/.ssh with
        # the perms sshd enforces (0700 dir, 0600 priv), chowned to uid 1001
        # so the dropped opencode process can read it, and write ~/.ssh/config
        # so plain `git@${GIT_FQDN}` clones route to :2222. Script body in
        # data/opencode/configure-git-ssh.sh.
        init_container {
          name              = "setup-git-ssh"
          image             = var.image_busybox
          image_pull_policy = "Always"
          command           = ["sh", "/etc/opencode-git/configure-git-ssh.sh"]
          env {
            name  = "GIT_FQDN"
            value = local.opencode_git_fqdn
          }
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
          volume_mount {
            name       = "opencode-ssh"
            mount_path = "/home/user/.ssh"
          }
          volume_mount {
            name       = "opencode-git-script"
            mount_path = "/etc/opencode-git"
            read_only  = true
          }
        }

        # The container STARTS as root (no run_as_user / run_as_non_root):
        # the entrypoint needs root to finalize the sshd host key + /etc/opk
        # perms and to run sshd-as-root, THEN drops to the unprivileged `user`
        # (uid 1001) to exec opencode (see data/opencode/entrypoint.sh). So
        # the agent never runs as root, but sshd can still offer root login.
        #
        # fs_group=0 (kept) lets the root entrypoint do its boot-time setup;
        # the entrypoint then `chown -R`s the writable mounts (PVC + .ssh) to
        # uid 1001 — that runtime chown, not fsGroup, is
        # the authoritative ownership fix (fsGroup=1001 wouldn't repair the
        # pre-existing root-owned PVC files and would re-trigger the sshd
        # host-key 0600 workaround).
        security_context {
          fs_group = 0
        }

        # opencode `web` server
        container {
          name              = "opencode"
          image             = local.opencode_image
          image_pull_policy = "Always"

          port {
            container_port = 4096
            name           = "opencode"
          }
          # sshd (opkssh-backed) runs in this container. Reachable on the
          # pod's tailnet IP via the tailscale sidecar; pod-network :22 is
          # blocked by the netpol default-deny baseline. Declared for
          # visibility only — no k8s Service fronts it (tailnet-direct).
          port {
            container_port = 22
            name           = "ssh"
          }

          env {
            name  = "OPENCODE_CONFIG"
            value = "/etc/opencode/opencode.json"
          }
          env {
            name  = "HOME"
            value = "/home/user"
          }
          # Forgejo CLI (fj) + API access. FORGEJO_HOST is the forge's FQDN (the
          # keys.json host key); FORGEJO_TOKEN is the scoped PAT
          # (write:repository,write:issue) the git bootstrap mints for the
          # RESTRICTED opencode user and patches into the opencode-forgejo-token
          # Secret (token-only — the account password never reaches this pod).
          # optional=true: the Secret starts empty (TF placeholder) until the
          # bootstrap patches it; Reloader (annotation below) rolls the pod then.
          # The entrypoint writes fj's keys.json from these; absent token = skip.
          env {
            name  = "FORGEJO_HOST"
            value = local.opencode_git_fqdn
          }
          env {
            name = "FORGEJO_TOKEN"
            value_from {
              secret_key_ref {
                name     = kubernetes_secret.opencode_forgejo_token.metadata[0].name
                key      = "token"
                optional = true
              }
            }
          }
          env {
            name = "LITELLM_API_KEY"
            value_from {
              secret_key_ref {
                name = module.opencode_tls_vault.config_secret_name
                key  = "litellm_api_key"
              }
            }
          }
          env {
            name = "MCP_API_KEY"
            value_from {
              secret_key_ref {
                name = module.opencode_tls_vault.config_secret_name
                key  = "mcp_api_key"
              }
            }
          }

          volume_mount {
            name       = "opencode-config"
            mount_path = "/etc/opencode"
            read_only  = true
          }
          # Opencode-global skills. ConfigMap `opencode-skills` carries one
          # key per skill name; the `items` mapping on the volume below
          # projects each key as `<name>/SKILL.md` so opencode's discovery
          # glob (~/.config/opencode/skills/<name>/SKILL.md) finds them.
          volume_mount {
            name       = "opencode-skills"
            mount_path = "/home/user/.config/opencode/skills"
            read_only  = true
          }
          # Pod-wide Rust AGENTS.md. Mounted into opencode's GLOBAL rule
          # slot (~/.config/opencode/AGENTS.md = /home/user/.config/opencode/...)
          # per opencode's docs/rules: opencode loads three independent
          # categories — local parent-walk, global, Claude-Code-global —
          # and combines them all. Putting the file in the global slot
          # means it ALWAYS loads, even when a cloned repo ships its own
          # AGENTS.md inside /home/user/working/<repo>/ (which is the local
          # category and DOESN'T shadow the global one). Mounting at
          # /home/user/AGENTS.md instead would be wrong: parent-walk stops at
          # the first match, so a repo-local AGENTS.md would silently
          # shadow the pod-wide guide.
          volume_mount {
            name       = "opencode-rust-agents"
            mount_path = "/home/user/.config/opencode/AGENTS.md"
            sub_path   = "AGENTS.md"
            read_only  = true
          }
          # Persistent state: sessions, MCP OAuth tokens, npm-installed
          # provider sdks. PVC mount covers the whole opencode share dir.
          volume_mount {
            name       = "opencode-data"
            mount_path = "/home/user/.local/share/opencode"
          }
          # opencode's CWD (/home/user/working — set as WORKDIR in the
          # Dockerfile). Same PVC, separate subPath so clones and
          # scratch files survive pod restarts but stay logically
          # separate from opencode's session/auth state at PVC root.
          volume_mount {
            name       = "opencode-data"
            mount_path = "/home/user/working"
            sub_path   = "working"
          }
          # ~/.ssh is materialized fresh at every pod start by the
          # setup-git-ssh init container from /mnt/secrets. Pure emptyDir
          # (no PVC) so a key rotation just gets picked up on the next
          # roll without leftover state.
          volume_mount {
            name       = "opencode-ssh"
            mount_path = "/home/user/.ssh"
          }
          # opkssh server config (providers + auth_id). entrypoint.sh copies
          # these into /etc/opk with the root:opksshuser 640 perms opkssh
          # enforces on auth_id (ConfigMap mounts are read-only root:root).
          volume_mount {
            name       = "opencode-opk"
            mount_path = "/etc/opk-src"
            read_only  = true
          }
          # npm + cargo → in-cluster cooldown proxies. .npmrc per account (npm
          # has no shared home); cargo config in the shared CARGO_HOME so both
          # `user` and root SSH sessions pick it up from one file.
          volume_mount {
            name       = "pkg-proxy-config"
            mount_path = "/home/user/.npmrc"
            sub_path   = "npmrc"
            read_only  = true
          }
          volume_mount {
            name       = "pkg-proxy-config"
            mount_path = "/root/.npmrc"
            sub_path   = "npmrc"
            read_only  = true
          }
          volume_mount {
            name       = "pkg-proxy-config"
            mount_path = "/usr/local/cargo/config.toml"
            sub_path   = "cargo-config.toml"
            read_only  = true
          }
          # uv → 7-day PyPI cooldown, system-level config for all users / any cwd.
          volume_mount {
            name       = "pkg-proxy-config"
            mount_path = "/etc/uv/uv.toml"
            sub_path   = "uv.toml"
            read_only  = true
          }

          # UNPRIVILEGED, locked down. The container starts as root (entrypoint
          # needs it for sshd + the host-key/chown setup), then drops opencode to
          # uid 1001 (`user`) via setpriv. Nothing in the pod needs privilege
          # escalation:
          #   - allow_privilege_escalation = false → no_new_privs, and the image
          #     strips ALL setuid bits (Dockerfile §5i) + has no sudo, so `user`
          #     has no path back to root (only opkssh sshd grants root).
          #   - default seccomp (RuntimeDefault, no Unconfined override).
          # Do NOT set run_as_user/run_as_non_root (must start as root). This is a
          # high-risk agent sandbox — keep it tight.
          security_context {
            privileged                 = false
            allow_privilege_escalation = false
          }

          resources {
            requests = { cpu = "400m", memory = "2Gi" }
            limits   = { cpu = "6", memory = "12Gi" }
          }

          readiness_probe {
            tcp_socket { port = 4096 }
            initial_delay_seconds = 15
            period_seconds        = 10
          }

          liveness_probe {
            tcp_socket { port = 4096 }
            initial_delay_seconds = 60
            period_seconds        = 30
            failure_threshold     = 5
          }
        }

        # oauth2-proxy: handles the OIDC code+PKCE flow against Zitadel
        # for browser sessions, and validates Authorization: Bearer JWTs
        # for the desktop `opencode attach` CLI path. Listens on
        # 127.0.0.1:4180 — only nginx in this same pod reaches it.
        container {
          name              = "oauth2-proxy"
          image             = var.image_oauth2_proxy
          image_pull_policy = "Always"

          env {
            name  = "OAUTH2_PROXY_PROVIDER"
            value = "oidc"
          }
          env {
            name  = "OAUTH2_PROXY_OIDC_ISSUER_URL"
            value = "https://${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${local.magic_fqdn_suffix}"
          }
          env {
            name  = "OAUTH2_PROXY_REDIRECT_URL"
            value = "https://${local.opencode_fqdn}/oauth2/callback"
          }
          env {
            name  = "OAUTH2_PROXY_HTTP_ADDRESS"
            value = "127.0.0.1:4180"
          }
          env {
            name  = "OAUTH2_PROXY_REVERSE_PROXY"
            value = "true"
          }
          # Auth-only mode. nginx talks to opencode directly; oauth2-proxy
          # just answers the /oauth2/auth subrequest.
          env {
            name  = "OAUTH2_PROXY_UPSTREAMS"
            value = "static://202"
          }
          # Project access is enforced upstream by Zitadel
          # has_project_check=true (only the personal user is granted),
          # so email-domain filtering is unnecessary.
          env {
            name  = "OAUTH2_PROXY_EMAIL_DOMAINS"
            value = "*"
          }
          env {
            name  = "OAUTH2_PROXY_SCOPE"
            value = "openid email profile"
          }
          env {
            name  = "OAUTH2_PROXY_SET_XAUTHREQUEST"
            value = "true"
          }
          env {
            name  = "OAUTH2_PROXY_PASS_USER_HEADERS"
            value = "true"
          }
          env {
            name  = "OAUTH2_PROXY_SKIP_PROVIDER_BUTTON"
            value = "true"
          }
          env {
            name  = "OAUTH2_PROXY_COOKIE_SECURE"
            value = "true"
          }
          env {
            name  = "OAUTH2_PROXY_COOKIE_DOMAINS"
            value = local.opencode_fqdn
          }
          env {
            name  = "OAUTH2_PROXY_WHITELIST_DOMAINS"
            value = "${local.opencode_fqdn},${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${local.magic_fqdn_suffix}"
          }
          # ─── CLI bearer-JWT bypass ─────────────────────────────────
          # Requests with `Authorization: Bearer <jwt>` validate against
          # Zitadel's JWKS and pass auth_request without a cookie. The
          # bearer must be a JWT (Zitadel id_token or, with
          # access_token_type=JWT on the OIDC app above, access_token).
          # Zitadel PATs are opaque and would NOT validate here — those
          # are service-account-only anyway. Desktop tooling runs the
          # OIDC code+refresh flow (e.g. via oauth2c or a small helper)
          # and exports the current JWT for opencode CLI and git CLI.
          # Browser flows still use the cookie path.
          env {
            name  = "OAUTH2_PROXY_SKIP_JWT_BEARER_TOKENS"
            value = "true"
          }
          env {
            name  = "OAUTH2_PROXY_EXTRA_JWT_ISSUERS"
            value = "https://${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${local.magic_fqdn_suffix}=${zitadel_application_oidc.opencode.client_id}"
          }

          env {
            name = "OAUTH2_PROXY_CLIENT_ID"
            value_from {
              secret_key_ref {
                name = module.opencode_tls_vault.config_secret_name
                key  = "oidc_client_id"
              }
            }
          }
          env {
            name = "OAUTH2_PROXY_CLIENT_SECRET"
            value_from {
              secret_key_ref {
                name = module.opencode_tls_vault.config_secret_name
                key  = "oidc_client_secret"
              }
            }
          }
          env {
            name = "OAUTH2_PROXY_COOKIE_SECRET"
            value_from {
              secret_key_ref {
                name = module.opencode_tls_vault.config_secret_name
                key  = "oauth2_cookie_secret"
              }
            }
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }
        }

        # Nginx: TLS termination + auth_request gate.
        container {
          name              = "nginx"
          image             = var.image_nginx
          image_pull_policy = "Always"

          port {
            container_port = 443
            name           = "https"
          }

          volume_mount {
            name       = "opencode-tls"
            mount_path = "/etc/nginx/certs"
            read_only  = true
          }
          volume_mount {
            name       = "nginx-config"
            mount_path = "/etc/nginx/nginx.conf"
            sub_path   = "nginx.conf"
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }
        }

        # Tailscale ingress sidecar. Advertises opencode.<hs>.<magic>
        # under the `opencode` headscale user.
        container {
          name              = "tailscale"
          image             = var.image_tailscale
          image_pull_policy = "Always"

          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          env {
            name  = "TS_KUBE_SECRET"
            value = module.opencode_tailscale.state_secret_name
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = module.opencode_tailscale.auth_secret_name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name  = "TS_HOSTNAME"
            value = var.opencode_domain
          }
          env {
            name  = "TS_EXTRA_ARGS"
            value = "--login-server=https://${data.terraform_remote_state.homelab.outputs.headscale_server_fqdn}"
          }
          env {
            name  = "TS_TAILSCALED_EXTRA_ARGS"
            value = "--port=41641"
          }

          security_context {
            capabilities {
              add = ["NET_ADMIN"]
            }
          }

          volume_mount {
            name       = "dev-net-tun"
            mount_path = "/dev/net/tun"
          }
          volume_mount {
            name       = "tailscale-state"
            mount_path = "/var/lib/tailscale"
          }

          resources {
            requests = { cpu = "20m", memory = "64Mi" }
            limits   = { cpu = "200m", memory = "256Mi" }
          }
        }

        # Volumes
        volume {
          name = "opencode-config"
          config_map {
            name = kubernetes_config_map.opencode_config.metadata[0].name
          }
        }
        # Each CM key holds one skill's SKILL.md body; the items mapping
        # projects them as <name>/SKILL.md so opencode discovery sees one
        # skill dir per key. The keys and the items both come from the same
        # data/opencode/skills/* fileset (local.opencode_skill_names in
        # services/opencode-skills.tf), so adding a skill = dropping a
        # data/opencode/skills/<name>/SKILL.md file — nothing to edit here.
        volume {
          name = "opencode-skills"
          config_map {
            name = kubernetes_config_map.opencode_skills.metadata[0].name
            dynamic "items" {
              for_each = local.opencode_skill_names
              content {
                key  = items.value
                path = "${items.value}/SKILL.md"
              }
            }
          }
        }
        volume {
          name = "opencode-rust-agents"
          config_map {
            name = kubernetes_config_map.opencode_rust_agents.metadata[0].name
          }
        }
        volume {
          name = "opencode-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.opencode_data.metadata[0].name
          }
        }
        volume {
          name = "opencode-tls"
          secret { secret_name = module.opencode_tls_vault.tls_secret_name }
        }
        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.opencode_nginx_config.metadata[0].name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = module.opencode_tls_vault.spc_name
            }
          }
        }
        volume {
          name = "dev-net-tun"
          host_path {
            path = "/dev/net/tun"
            type = "CharDevice"
          }
        }
        volume {
          name = "tailscale-state"
          empty_dir {}
        }
        volume {
          name = "opencode-ssh"
          empty_dir {}
        }
        volume {
          name = "opencode-git-script"
          config_map {
            name         = kubernetes_config_map.opencode_git_script.metadata[0].name
            default_mode = "0555"
          }
        }
        volume {
          name = "opencode-opk"
          config_map {
            name = kubernetes_config_map.opencode_opk.metadata[0].name
          }
        }
        volume {
          name = "pkg-proxy-config"
          config_map {
            name = kubernetes_config_map.opencode_pkg_proxy_config.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [
    module.opencode_tls_vault,
    module.opencode_build,
  ]

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
    ]
  }
}

resource "kubernetes_service" "opencode" {
  metadata {
    name      = "opencode"
    namespace = kubernetes_namespace.opencode.metadata[0].name
  }
  spec {
    selector = { app = "opencode" }
    port {
      name        = "https"
      port        = 443
      target_port = 443
    }
  }
}
