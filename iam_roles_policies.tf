# IAM policy documents
resource "aws_iam_service_linked_role" "spot" {
  count            = var.create_spot_role ? 1 : 0
  aws_service_name = "spot.amazonaws.com"
}

# Lambda Assume Role Policy Document
data "aws_iam_policy_document" "lambda_assume_role_doc" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# Lambda Execution Permissions Policy Document
data "aws_iam_policy_document" "lambda_policy_doc" {

  statement {
    sid       = "SecretsManagerAccess"
    actions   = ["secretsmanager:GetSecretValue"]
    effect    = "Allow"
    resources = [data.aws_secretsmanager_secret.github_app.arn]
  }

  statement {
    sid     = "EC2RunInstances"
    actions = ["ec2:RunInstances"]
    effect  = "Allow"
    resources = [
      "arn:aws:ec2:*:*:instance/*",
      "arn:aws:ec2:*:*:subnet/*",
      "arn:aws:ec2:*:*:security-group/*",
      "arn:aws:ec2:*:*:network-interface/*",
      "arn:aws:ec2:*:*:volume/*",
      "arn:aws:ec2:*:*:launch-template/*",
      "arn:aws:ec2:*::image/*"
    ]
  }

  statement {
    sid     = "EC2Describe"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribeLaunchTemplateVersions"
    ]
    effect    = "Allow"
    resources = ["*"]
  }

  statement {
    sid       = "EC2CreateTags"
    actions   = ["ec2:CreateTags"]
    effect    = "Allow"
    resources = ["*"]
  }

  statement {
    sid     = "EC2RestrictedTerminate"
    actions = ["ec2:TerminateInstances"]
    effect  = "Allow"
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/Team"
      values   = [var.Team]
    }
  }

  statement {
    sid       = "IAMPassRole"
    actions   = ["iam:PassRole"]
    effect    = "Allow"
    resources = [aws_iam_role.runner_role.arn]
  }

  statement {
    sid     = "VPCAccess"
    actions = [
      "ec2:CreateNetworkInterface",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DeleteNetworkInterface"
    ]
    effect    = "Allow"
    resources = ["*"]
  }

  statement {
    sid     = "SQSConsumption"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes"
    ]
    effect    = "Allow"
    resources = [aws_sqs_queue.runner_queue.arn]
  }

  # ← ADDED: Lambda needs SendMessage to write failed jobs to DLQ
  statement {
    sid       = "SQSDLQSendMessage"
    actions   = ["sqs:SendMessage"]
    effect    = "Allow"
    resources = [aws_sqs_queue.runner_queue_dead_letter.arn]
  }
}

resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_sqs_execution" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaSQSQueueExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_vpc_access" {
  count      = length(var.lambda_subnets) > 0 ? 1 : 0
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# EC2 Runner Assume Role Policy Document
data "aws_iam_policy_document" "runner_assume_role_doc" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# EC2 Runner Permissions Policy Document
data "aws_iam_policy_document" "runner_policy_doc" {

  statement {
    sid     = "CloudWatchLogs"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    effect    = "Allow"
    resources = ["arn:aws:logs:*:*:log-group:/aws/ec2/github-runner:*"]
  }

  statement {
    sid       = "SecretsManagerAccess"
    actions   = ["secretsmanager:GetSecretValue"]
    effect    = "Allow"
    resources = [data.aws_secretsmanager_secret.github_app.arn]
  }

  statement {
    sid       = "KMSDecrypt"
    actions   = ["kms:Decrypt"]
    effect    = "Allow"
    resources = var.kms_key_arn != null ? [var.kms_key_arn] : ["*"]
  }
}

# API Gateway Assume Role Policy Document
data "aws_iam_policy_document" "apigw_sqs_assume_role_doc" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"
    principals {
      type        = "Service"
      identifiers = ["apigateway.amazonaws.com"]
    }
  }
}

# API Gateway SQS Send Message Policy Document
data "aws_iam_policy_document" "apigw_sqs_policy_doc" {
  statement {
    sid       = "SQSSendMessage"
    actions   = ["sqs:SendMessage"]
    effect    = "Allow"
    resources = [aws_sqs_queue.runner_queue.arn]
  }
}

# Lambda Execution Role
resource "aws_iam_role" "lambda_exec_role" {
  name               = "${local.resource_name_prefix}-lambda-exec-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role_doc.json
  tags               = local.propagated_tags
}

resource "aws_iam_policy" "lambda_policy" {
  name   = "${local.resource_name_prefix}-lambda-policy"
  policy = data.aws_iam_policy_document.lambda_policy_doc.json
  tags   = local.propagated_tags
}

resource "aws_iam_role_policy_attachment" "lambda_attach_policy" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = aws_iam_policy.lambda_policy.arn
}

# EC2 Instance Profile Role
resource "aws_iam_role" "runner_role" {
  name               = "${local.resource_name_prefix}-runner-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.runner_assume_role_doc.json
  tags               = local.propagated_tags
}

resource "aws_iam_instance_profile" "runner_instance_profile" {
  name = "${local.resource_name_prefix}-runner-profile"
  role = aws_iam_role.runner_role.name
  tags = local.propagated_tags
}

resource "aws_iam_policy" "runner_policy" {
  name   = "${local.resource_name_prefix}-runner-ec2-policy"
  policy = data.aws_iam_policy_document.runner_policy_doc.json
  tags   = local.propagated_tags
}

resource "aws_iam_role_policy_attachment" "runner_attach_policy" {
  role       = aws_iam_role.runner_role.name
  policy_arn = aws_iam_policy.runner_policy.arn
}

resource "aws_iam_role_policy_attachment" "runner_attach_ssm" {
  role       = aws_iam_role.runner_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# API Gateway IAM Role (to send messages to SQS)
resource "aws_iam_role" "apigw_sqs_role" {
  name               = "${local.resource_name_prefix}-apigw-sqs-role"
  assume_role_policy = data.aws_iam_policy_document.apigw_sqs_assume_role_doc.json
  tags               = local.propagated_tags
}

resource "aws_iam_policy" "apigw_sqs_policy" {
  name   = "${local.resource_name_prefix}-apigw-sqs-policy"
  policy = data.aws_iam_policy_document.apigw_sqs_policy_doc.json
  tags   = local.propagated_tags
}

resource "aws_iam_role_policy_attachment" "apigw_sqs_attach_policy" {
  role       = aws_iam_role.apigw_sqs_role.name
  policy_arn = aws_iam_policy.apigw_sqs_policy.arn
}

# IAM role for API Gateway to write to CloudWatch
resource "aws_iam_role" "apigw_cloudwatch_role" {
  name = "${local.resource_name_prefix}-apigw-cloudwatch-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = {
        Service = "apigateway.amazonaws.com"
      }
    }]
  })

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
