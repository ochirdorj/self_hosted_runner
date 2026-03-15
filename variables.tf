  variable "image_id" {
    type = string
    description = "AMI image ID"
  }

  variable "instance_type" {
    type = list(string)
    description = "ec2 instance type"
  }

  variable "tags" {
    type = map(string)
    description = "tag of the resource"
  }

variable "Environment" {
  type = string
  description = "tag for asg"
}

variable "Managed_by" {
  type = string
  description = "Managed by tag"
}

variable "Project" {
  type = string
  description = "tag for asg"
}

variable "Team" {
  type = string
  description = "tag for asg"
}

variable "Owner" {
  type = string
  description = "tag for asg"
}

variable "root_volume_size" {
  type = number
  description = "size of ebs volume"
}

variable "vpc_id" {
  type = string
  description = "VPC ID"
}

variable "lambda_subnets" {
  type = list(string)
  description = "private subnets"
}

variable "region" {
  type = string
  description = "aws region"
}

variable "github_app_credentials_secret_name" {
    type = string
    description = "just leave it as is"
  }

  variable "github_owner" {
    type = string
    description = "name of the organization or repo"
  }

variable "runner_labels" {
  type = string
  description = "runner labels"
}

variable "launch_template" {
  type = string
  description = "name of the launch template"
}

variable "create_spot_role" {
  type = bool
  description = "enable or disable service linked role"
}
variable "stage_name" {
type = string
description = "API Gateway stage name"  
}

variable "kms_key_arn" {
  type = string
  description = "KMS Key ARN for encrypting secrets (optional, but recommended)"
}