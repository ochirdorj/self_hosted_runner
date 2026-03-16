# 4. Security Group
resource "aws_security_group" "lambda_sg" {
  count       = length(var.lambda_subnets) > 0 ? 1 : 0
  name        = "${local.resource_name_prefix}-lambda-runner-sg"
  description = "Allow outbound traffic from Lambda"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.propagated_tags, {
    Name = "${local.resource_name_prefix}-lambda-runner-sg"
  })
}

# Lambda: Runner Manager
resource "aws_lambda_function" "runner_manager" {
  filename         = var.lambda_zip_path
  function_name    = "${local.resource_name_prefix}-runner-manager"
  role             = aws_iam_role.lambda_exec_role.arn
  handler          = "index.handler"
  runtime          = "nodejs22.x"
  source_code_hash = fileexists(var.lambda_zip_path) ? filebase64sha256(var.lambda_zip_path) : null
  architectures    = ["x86_64"]
  timeout          = 30
  memory_size      = 512

  lifecycle {
    create_before_destroy = true
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.runner_queue_dead_letter.arn
  }

  environment {
    variables = {
      SECRET_NAME    = var.github_app_credentials_secret_name
      LT_NAME        = var.launch_template
      GH_LABELS      = var.runner_labels
      SUBNET_IDS     = join(",", var.lambda_subnets)
      SG_ID          = aws_security_group.runner.id
      INSTANCE_TYPES = join(",", var.instance_type)
    }
  }

  dynamic "vpc_config" {
    for_each = length(var.lambda_subnets) > 0 ? [1] : []
    content {
      subnet_ids         = var.lambda_subnets
      security_group_ids = aws_security_group.lambda_sg[*].id
    }
  }

  tags = local.propagated_tags
}

resource "aws_iam_role_policy_attachment" "apigw_cloudwatch_attach" {
  role       = aws_iam_role.apigw_cloudwatch_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

# Account-level setting — tells API Gateway which role to use for CloudWatch
resource "aws_api_gateway_account" "main" {
  cloudwatch_role_arn = aws_iam_role.apigw_cloudwatch_role.arn
}

# Wait for IAM to propagate before creating Lambda
resource "time_sleep" "wait_for_iam_propagation" {
  create_duration = "30s"

  depends_on = [
    aws_iam_role_policy_attachment.lambda_attach_policy,
    aws_iam_role_policy_attachment.lambda_basic_execution,
    aws_iam_role_policy_attachment.lambda_sqs_execution,
    aws_iam_role_policy_attachment.lambda_vpc_access,
  ]
}
