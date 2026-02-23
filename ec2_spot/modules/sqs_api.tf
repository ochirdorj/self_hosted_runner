# SQS QUEUE AND API GATEWAY

resource "aws_sqs_queue" "runner_queue_dead_letter" {
  name = "github-runner-job-queue-dlq"
  tags = var.tags
}

# Main SQS Queue (Throttling & Decoupling)
resource "aws_sqs_queue" "runner_queue" {
  name                        = "github-runner-job-queue"
  delay_seconds               = 0
  max_message_size            = 262144
  message_retention_seconds   = 345600 # 4 days
  receive_wait_time_seconds   = 10
  visibility_timeout_seconds  = 300    # 5 minutes

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.runner_queue_dead_letter.arn
    maxReceiveCount     = 3 # Retries 3 times before moving to DLQ
  })

  tags = var.tags
}

# API Gateway (Entry point for GitHub Webhook)
resource "aws_api_gateway_rest_api" "github_webhook_api" {
  name        = "GitHubRunnerWebhookAPI"
  description = "Endpoint for GitHub Actions workflow_job webhooks."
  tags = var.tags
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

# Integration: API Gateway -> SQS
resource "aws_api_gateway_integration" "sqs_integration" {
  rest_api_id             = aws_api_gateway_rest_api.github_webhook_api.id
  resource_id             = aws_api_gateway_resource.webhook_resource.id
  http_method             = aws_api_gateway_method.post_method.http_method
  type                    = "AWS"
  integration_http_method = "POST"
  
  uri                     = "arn:aws:apigateway:${data.aws_region.current.id}:sqs:path/${data.aws_caller_identity.current.account_id}/${aws_sqs_queue.runner_queue.name}"
  
  credentials             = aws_iam_role.apigw_sqs_role.arn
  passthrough_behavior    = "NEVER"

  request_parameters = {
    "integration.request.header.Content-Type" = "'application/x-www-form-urlencoded'"
  }

  request_templates = {
    "application/json" = <<-EOF
      Action=SendMessage&MessageBody=$input.body
      EOF
  }
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

resource "aws_api_gateway_integration_response" "sqs_integration_response" {
  rest_api_id             = aws_api_gateway_rest_api.github_webhook_api.id
  resource_id             = aws_api_gateway_resource.webhook_resource.id
  http_method             = aws_api_gateway_method.post_method.http_method
  status_code             = aws_api_gateway_method_response.success_response.status_code
  depends_on = [ aws_api_gateway_integration.sqs_integration ]
  selection_pattern       = "200"
  response_templates      = {
    "application/json" = "{ \"status\": \"OK\" }"
  }
}

resource "aws_api_gateway_deployment" "deployment" {
  rest_api_id = aws_api_gateway_rest_api.github_webhook_api.id
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
  stage_name    = "dev"
  tags = var.tags
}