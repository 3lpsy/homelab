terraform {
  backend "local" {}
}


data "terraform_remote_state" "homelab" {
  backend = "local"
  config = {
    path = "${var.state_dirs}/homelab/terraform.tfstate"
  }
}

data "terraform_remote_state" "vault_conf" {
  backend = "local"
  config = {
    path = "${var.state_dirs}/vault-conf/terraform.tfstate"
  }
}
