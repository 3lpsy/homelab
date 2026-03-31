terraform {
  backend "local" {}
}

data "terraform_remote_state" "vault" {
  backend = "local"

  config = {
    path = "${var.state_dirs}/vault/terraform.tfstate"
  }
}
