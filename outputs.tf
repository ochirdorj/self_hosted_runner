output "ami_id" {
  description = "ID of the pre-baked GitHub Actions runner AMI"
  value       = aws_ami_from_instance.runner.id
}

output "ami_name" {
  description = "Name of the pre-baked AMI"
  value       = aws_ami_from_instance.runner.name
}

output "ssm_parameter_name" {
  description = "SSM parameter name storing the AMI ID (use this to reference across modules)"
  value       = aws_ssm_parameter.runner_ami.name
}
