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
  type = string
}

variable "tailnet_auth_key" {
  type      = string
  sensitive = true
}
variable "headscale_server_domain" {
  type = string
}

variable "skip_nvidia_install" {
  type        = bool
  default     = false
  description = "Skip NVIDIA driver install (use true with DLAMI)"
}

variable "root_volume_size" {
  type    = number
  default = 300
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
  type = string
}

variable "default_model" {
  type = string
}
variable "efficient_model" {
  type        = string
  description = "Fast MoE model for bulk/repetitive tasks — pulled but not loaded into VRAM"
}

variable "spot_max_price" {
  type    = string
  default = "1.625"
}

variable "ollama_context_length" {
  type        = number
  default     = 65536 # 64K - good balance for agentic coding
  description = "Default context window for all models"
}

variable "ollama_kv_cache_type" {
  type        = string
  default     = "q8_0"
  description = "KV cache quantization - q8_0 saves ~40% VRAM vs f16"
}
variable "ollama_keep_alive" {
  type        = string
  default     = "30m"
  description = "How long to keep model loaded in VRAM after last request"
}
