terraform {
  required_version = "~> 1.14.0"
  required_providers {
    aws = {
        version = "~> 6.10.0"
        source = "hashicorp/aws"
    }
    archive = {
      source = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}