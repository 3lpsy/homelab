variable "ssh_pub_key" {
  type = string
}
variable "ssh_priv_key" {
  type      = string
  sensitive = true
}
variable "ssh_user" {
  type = string
}
variable "ec2_user" {
  type    = string
  default = "ubuntu"
}

variable "tailnet_auth_key" {
  type      = string
  sensitive = true
}
variable "headscale_server_domain" {
  type = string
}

variable "ami" {
  type = string
}
variable "vpc_id" {
  type = string
}
variable "subnet_id" {
  type = string
}
variable "instance_type" {
  type    = string
  default = "t3.small"
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "bedrock_models" {
  description = "Map of alias name to Bedrock model config (id + optional max output tokens)"
  type = map(object({
    model_id   = string
    max_tokens = optional(number)
  }))
}

variable "default_user_max_budget" {
  description = "Default max_budget (USD) applied to newly-created internal users. Acts as a per-user disaster cap."
  type        = number
  default     = 20
}
variable "litellm_port" {
  type    = number
  default = 4000
}

variable "ollama_tailnet_host" {
  description = "Tailnet hostname for ollama server (e.g. 'ollama')"
  type        = string
  default     = "ollama"
}

variable "ollama_port" {
  type    = number
  default = 11434
}

variable "litellm_models" {
  description = "Additional LiteLLM model entries (list of maps with model_name and litellm_model)"
  type = list(object({
    model_name    = string
    litellm_model = string
  }))
  default = []
}
