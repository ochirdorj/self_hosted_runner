terraform {
  backend "s3" {
    bucket = "infra-shs-use1-ap13-tf-backend-s3"
    key = "poc/self-hosted-runner/terraform.tfstate"
    region = "us-east-1"
    encrypt = true
  }
}