locals {
  litellm_config_yaml = yamlencode({
    model_list = [
      for alias, cfg in var.llm_models : {
        model_name = alias
        litellm_params = { for k, v in {
          model           = "${cfg.provider}/${cfg.model_id}"
          aws_region_name = cfg.provider == "bedrock" ? coalesce(cfg.aws_region, var.aws_region) : null
          max_tokens      = cfg.max_tokens
          cache_control_injection_points = cfg.provider == "bedrock" && can(regex("anthropic", cfg.model_id)) ? [
            { location = "message", role = "system" },
            { location = "message", index = -2 },
            { location = "message", index = -1 },
          ] : null
        } : k => v if v != null }
        model_info = { for k, v in {
          input_cost_per_token        = cfg.input_cost_per_token
          output_cost_per_token       = cfg.output_cost_per_token
          cache_read_input_token_cost = cfg.cache_read_input_token_cost
        } : k => v if v != null }
      }
    ]
    litellm_settings = {
      default_internal_user_params = {
        max_budget = var.litellm_default_user_max_budget
      }
      # Silently drop provider-unsupported params (e.g. tool_choice on Llama4
      # Maverick via Bedrock) instead of 400-ing the request.
      drop_params = true
    }
  })
}

resource "kubernetes_config_map" "litellm_config" {
  metadata {
    name      = "litellm-config"
    namespace = kubernetes_namespace.litellm.metadata[0].name
  }
  data = {
    "config.yaml" = local.litellm_config_yaml
  }
}

resource "kubernetes_config_map" "litellm_nginx_config" {
  metadata {
    name      = "litellm-nginx-config"
    namespace = kubernetes_namespace.litellm.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/litellm.nginx.conf.tpl", {
      server_domain = "${var.litellm_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
    })
  }
}
