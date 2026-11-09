terraform {
  backend "s3" {
    bucket       = "cicd-terraform-state-639493421189"
    key          = "cicd-webserver/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
