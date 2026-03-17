# ── BASE UBUNTU AMI (official Canonical) ──────────────────────────────────────
data "aws_ssm_parameter" "ubuntu_base" {
  name = "/aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id"
}

# ── TEMP SECURITY GROUP (SSH access during build) ─────────────────────────────
resource "aws_security_group" "ami_builder" {
  name        = "${local.resource_name_prefix}-ami-builder-sg"
  description = "Temporary SG for AMI builder instance"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound for package installs"
  }

  tags = merge(local.propagated_tags, {
    Name = "${local.resource_name_prefix}-ami-builder-sg"
  })
}

# ── TEMP EC2 INSTANCE ─────────────────────────────────────────────────────────
resource "aws_instance" "ami_builder" {
  ami                         = nonsensitive(data.aws_ssm_parameter.ubuntu_base.value)
  instance_type               = var.instance_type[0]
  subnet_id                   = var.lambda_subnets[0]
  vpc_security_group_ids      = [aws_security_group.ami_builder.id]
  iam_instance_profile        = aws_iam_instance_profile.ami_builder.name
  associate_public_ip_address = false

  user_data_base64 = base64encode(file("${path.module}/install.sh"))

  # Wait for user-data to finish before snapshotting
  user_data_replace_on_change = true

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  tags = merge(local.propagated_tags, {
    Name = "${local.resource_name_prefix}-ami-builder"
  })
}

# ── WAIT FOR INSTALL TO COMPLETE ──────────────────────────────────────────────
# Polls SSM until the install script writes "AMI install complete" to the log
resource "null_resource" "wait_for_install" {
  depends_on = [aws_instance.ami_builder]

  provisioner "local-exec" {
    command = <<-EOF
      echo "Waiting 15 minutes for AMI install to complete..."
      sleep 900
      echo "Wait complete, proceeding to create AMI..."
    EOF
  }
}

# ── CREATE AMI FROM INSTANCE ──────────────────────────────────────────────────
resource "aws_ami_from_instance" "runner" {
  depends_on         = [null_resource.wait_for_install]
  name               = "${local.resource_name_prefix}-runner-ami"
  source_instance_id = aws_instance.ami_builder.id
  snapshot_without_reboot = false

  tags = merge(local.propagated_tags, {
    Name = "${local.resource_name_prefix}-runner-ami"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# ── TERMINATE BUILDER INSTANCE ────────────────────────────────────────────────
resource "null_resource" "terminate_builder" {
  depends_on = [aws_ami_from_instance.runner]

  provisioner "local-exec" {
    command = <<-EOF
      echo "Terminating AMI builder instance ${aws_instance.ami_builder.id}..."
      aws ec2 terminate-instances \
        --instance-ids ${aws_instance.ami_builder.id} \
        --region ${var.aws_region}
      echo "Instance termination initiated."
    EOF
  }
}

# ── STORE AMI ID IN SSM PARAMETER ─────────────────────────────────────────────
# Makes it easy to reference across accounts / modules
resource "aws_ssm_parameter" "runner_ami" {
  depends_on  = [aws_ami_from_instance.runner]
  name        = "/${local.resource_name_prefix}/runner-ami-id"
  type        = "String"
  value       = aws_ami_from_instance.runner.id
  description = "Pre-baked GitHub Actions runner AMI"
  overwrite   = true

  tags = merge(local.propagated_tags, {
    Name = "${local.resource_name_prefix}-runner-ami-id-param"
  })
}
