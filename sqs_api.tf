# SQS QUEUE AND API GATEWAY

resource "aws_sqs_queue" "runner_queue_dead_letter" {
  name = "${local.resource_name_prefix}-runner-queue-dlq"
  tags = local.propagated_tags
  sqs_managed_sse_enabled = true
}

# Main SQS Queue (Throttling & Decoupling)
resource "aws_sqs_queue" "runner_queue" {
  name                        = "${local.resource_name_prefix}-runner-queue"
  delay_seconds               = 0
  max_message_size            = 262144
  message_retention_seconds   = 345600 # 4 days
  receive_wait_time_seconds   = 10
  visibility_timeout_seconds  = 300    # 5 minutes
  sqs_managed_sse_enabled = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.runner_queue_dead_letter.arn
    maxReceiveCount     = 3 # Retries 3 times before moving to DLQ
  })

  tags = local.propagated_tags
}

# API Gateway (Entry point for GitHub Webhook)
resource "aws_api_gateway_rest_api" "github_webhook_api" {
  name        = "${local.resource_name_prefix}-webhook-api"
  description = "Endpoint for GitHub Actions workflow_job webhooks."
  tags = local.propagated_tags
}

resource "aws_api_gateway_resource" "webhook_resource" {
  rest_api_id = aws_api_gateway_rest_api.github_webhook_api.id
  parent_id   = aws_api_gateway_rest_api.github_webhook_api.root_resource_id
  path_part   = "webhook"
}

resource "aws_api_gateway_method" "post_method" {
  rest_api_id   = aws_api_gateway_rest_api.github_webhook_api.id
  resource_id   = aws_api_gateway_resource.webhook_resource.id
  http_method   = "POST"
  authorization = "NONE" 
}

# Integration: API Gateway -> Webhook Validator Lambda
resource "aws_api_gateway_integration" "sqs_integration" {
  rest_api_id             = aws_api_gateway_rest_api.github_webhook_api.id
  resource_id             = aws_api_gateway_resource.webhook_resource.id
  http_method             = aws_api_gateway_method.post_method.http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.webhook_validator.invoke_arn
}

resource "aws_api_gateway_method_response" "success_response" {
  rest_api_id = aws_api_gateway_rest_api.github_webhook_api.id
  resource_id = aws_api_gateway_resource.webhook_resource.id
  http_method = aws_api_gateway_method.post_method.http_method
  status_code = "200"

  response_models = {
    "application/json" = "Empty"
  }
}


resource "aws_api_gateway_deployment" "deployment" {
  rest_api_id = aws_api_gateway_rest_api.github_webhook_api.id

  depends_on = [ aws_api_gateway_integration.sqs_integration ]

  triggers = {
    redeployment = sha1(join("", [
      jsonencode(aws_api_gateway_rest_api.github_webhook_api.body),
      jsonencode(aws_api_gateway_resource.webhook_resource.path_part),
      jsonencode(aws_api_gateway_method.post_method.http_method),
      jsonencode(aws_api_gateway_integration.sqs_integration.uri)
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "dev" {
  deployment_id = aws_api_gateway_deployment.deployment.id
  rest_api_id   = aws_api_gateway_rest_api.github_webhook_api.id
  stage_name    = var.stage_name   
  tags          = local.propagated_tags

  depends_on = [ aws_api_gateway_account.main ]

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway.arn
    format = jsonencode({
    requestId      = "$context.requestId"
    ip             = "$context.identity.sourceIp"
    requestTime    = "$context.requestTime"
    httpMethod     = "$context.httpMethod"
    resourcePath   = "$context.resourcePath"
    status         = "$context.status"
    responseLength = "$context.responseLength"
    errorMessage   = "$context.error.message"
    })
  }
}

resource "aws_api_gateway_method_settings" "throttling" {
  rest_api_id = aws_api_gateway_rest_api.github_webhook_api.id
  stage_name  = aws_api_gateway_stage.dev.stage_name
  method_path = "*/*"

  settings {
    throttling_burst_limit = 100
    throttling_rate_limit  = 50
    logging_level          = "INFO"
    data_trace_enabled     = false
    metrics_enabled        = true
  }
}

resource "aws_cloudwatch_log_group" "api_gateway" {
  name              = "/aws/apigateway/${local.resource_name_prefix}-webhook"
  retention_in_days = 30
  tags              = local.propagated_tags
}

resource "aws_cloudwatch_metric_alarm" "dlq_alarm" {
  alarm_name          = "${local.resource_name_prefix}-dlq-messages"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Messages in DLQ — runner job failed"

  dimensions = {
    QueueName = aws_sqs_queue.runner_queue_dead_letter.name
  }

  tags = local.propagated_tags
}