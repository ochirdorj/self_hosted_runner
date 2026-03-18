# IAM Role for Webhook Validator Lambda

data "aws_iam_policy_document" "webhook_validator_policy_doc" {
  statement {
    sid       = "SecretsManagerAccess"
    actions   = ["secretsmanager:GetSecretValue"]
    effect    = "Allow"
    resources = [data.aws_secretsmanager_secret.github_app.arn]
  }

  statement {
    sid       = "SQSSendMessage"
    actions   = ["sqs:SendMessage"]
    effect    = "Allow"
    resources = [aws_sqs_queue.runner_queue.arn]
  }
}

resource "aws_iam_role" "webhook_validator_role" {
  name               = "${local.resource_name_prefix}-webhook-validator-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role_doc.json
  tags               = local.propagated_tags
}

resource "aws_iam_policy" "webhook_validator_policy" {
  name   = "${local.resource_name_prefix}-webhook-validator-policy"
  policy = data.aws_iam_policy_document.webhook_validator_policy_doc.json
  tags   = local.propagated_tags
}

resource "aws_iam_role_policy_attachment" "webhook_validator_attach_policy" {
  role       = aws_iam_role.webhook_validator_role.name
  policy_arn = aws_iam_policy.webhook_validator_policy.arn
}

resource "aws_iam_role_policy_attachment" "webhook_validator_basic_execution" {
  role       = aws_iam_role.webhook_validator_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "webhook_validator_vpc_access" {
  count      = length(var.lambda_subnets) > 0 ? 1 : 0
  role       = aws_iam_role.webhook_validator_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# Webhook Validator Lambda

resource "aws_lambda_function" "webhook_validator" {
  filename         = var.webhook_lambda_zip_path
  function_name    = "${local.resource_name_prefix}-webhook-validator"
  role             = aws_iam_role.webhook_validator_role.arn
  handler          = "index.handler"
  runtime          = "nodejs22.x"
  source_code_hash = try(filebase64sha256(var.webhook_lambda_zip_path), null)
  architectures    = ["x86_64"]
  timeout          = 10
  memory_size      = 256

  environment {
    variables = {
      SECRET_NAME        = var.github_app_credentials_secret_name
      WEBHOOK_SECRET_KEY = var.webhook_secret_key
      SQS_QUEUE_URL      = aws_sqs_queue.runner_queue.url
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

# Allow API Gateway to invoke the webhook validator
resource "aws_lambda_permission" "apigw_invoke_webhook" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.webhook_validator.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.github_webhook_api.execution_arn}/*/*"
}

resource "aws_cloudwatch_log_group" "webhook_validator" {
  name              = "/aws/lambda/${local.resource_name_prefix}-webhook-validator"
  retention_in_days = 30
  tags              = local.propagated_tags
}
