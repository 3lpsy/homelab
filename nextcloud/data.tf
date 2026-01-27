data "terraform_remote_state" "homelab" {
  backend = "local"
  config = {
    path = "./../homelab/terraform.tfstate"
  }
}

data "terraform_remote_state" "vault" {
  backend = "local"
  config = {
    path = "./../vault/terraform.tfstate"
  }
}

data "terraform_remote_state" "vault_conf" {
  backend = "local"
  config = {
    path = "./../vault-conf/terraform.tfstate"
  }
}
