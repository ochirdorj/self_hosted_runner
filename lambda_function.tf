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
  source_code_hash = filebase64sha256(var.lambda_zip_path)
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

resource "aws_lambda_event_source_mapping" "github_sqs_trigger" {
  event_source_arn        = aws_sqs_queue.runner_queue.arn
  function_name           = aws_lambda_function.runner_manager.function_name
  function_response_types = ["ReportBatchItemFailures"]
  enabled                 = true
  batch_size              = 10
  tags                    = local.propagated_tags
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.resource_name_prefix}-runner-manager"
  retention_in_days = 30
  tags              = local.propagated_tags
}
