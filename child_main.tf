
# Data Sources 

data "aws_vpc" "existing" {
  id = var.vpc_id
}

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

data "aws_secretsmanager_secret" "github_app" {
  name = var.github_app_credentials_secret_name
}

data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id"
}

locals {
  resource_name_prefix = "${var.Environment}-${var.Managed_by}-${var.Project}-${var.Team}-${var.Owner}"

  propagated_tags = {
    Environment  = var.Environment
    Managed_By   = var.Managed_by
    Project      = var.Project
    Team         = var.Team
    Owner        = var.Owner
  }
}

# Security Group

resource "aws_security_group" "runner" {
  name        = "${local.resource_name_prefix}-runner-sg"
  description = "SG for ephemeral GitHub runners (SSM access only)"
  vpc_id      = data.aws_vpc.existing.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.propagated_tags, {
    Name = "${local.resource_name_prefix}-runner-sg"
  })
}


resource "aws_launch_template" "example" {
  name = var.launch_template
  image_id    = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type = var.instance_type[0]
  vpc_security_group_ids = [aws_security_group.runner.id]

  tags = merge(local.propagated_tags, {
    Name = "${local.resource_name_prefix}-launch-template"
  })

  lifecycle {
    create_before_destroy = true
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
    volume_size = var.root_volume_size
    volume_type = "gp3"
    delete_on_termination = true
    encrypted = true
    }
  }
  
  monitoring {
    enabled = true
  }

  iam_instance_profile {
    name = aws_iam_instance_profile.runner_instance_profile.name
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(local.propagated_tags, {
      Name = "self-hosted-runner-disk"
    })
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.propagated_tags, {
      Name = "${local.resource_name_prefix}-runner"
    })
    }
  
    metadata_options {
    http_endpoint           = "enabled"
    http_tokens             = "required"
    http_put_response_hop_limit = 2
  }
  }