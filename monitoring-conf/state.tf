terraform {
  backend "local" {}
}

data "terraform_remote_state" "services" {
  backend = "local"
  config = {
    path = "${var.state_dirs}/services/terraform.tfstate"
  }
}
