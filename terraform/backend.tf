terraform {
  backend "s3" {
    bucket       = "cicd-terraform-state-625830751097"
    key          = "cicd-webserver/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
