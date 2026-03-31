terraform {
  backend "local" {}
}

data "terraform_remote_state" "monitoring" {
  backend = "local"
  config = {
    path = "${var.state_dirs}/monitoring/terraform.tfstate"
  }
}
