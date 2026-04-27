terraform {
  backend "local" {}
}

data "terraform_remote_state" "homelab" {
  backend = "local"
  config = {
    path = "${var.state_dirs}/homelab/terraform.tfstate"
  }
}

data "terraform_remote_state" "cluster" {
  backend = "local"
  config = {
    path = "${var.state_dirs}/cluster/terraform.tfstate"
  }
}
