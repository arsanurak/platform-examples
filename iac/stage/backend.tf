# Where state would live if this root were ever applied. The bucket is a
# placeholder; `make validate` and `terraform test` never touch it.

terraform {
  backend "s3" {
    bucket       = "example-terraform-state-000000000000"
    key          = "stage/terraform.tfstate"
    region       = "eu-west-1"
    encrypt      = true
    use_lockfile = true
  }
}
