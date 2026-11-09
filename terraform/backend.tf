terraform {
  backend "s3" {
    bucket       = "cicd-terraform-state-177602935884"
    key          = "cicd-webserver/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
