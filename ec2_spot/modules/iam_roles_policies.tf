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
    sid     = "SecretsManagerAccess"
    actions = ["secretsmanager:GetSecretValue"]
    effect  = "Allow"
    resources = [data.aws_secretsmanager_secret.github_app.arn]
  }
  
  # Ec2 instance role
  statement {
    sid     = "EC2GeneralManagement"
    actions = [
     "ec2:RunInstances",
    "ec2:DescribeInstances",
    "ec2:CreateTags",
    "ec2:DescribeLaunchTemplates",
    "ec2:DescribeLaunchTemplateVersions"
    ]
    effect = "Allow"
    resources = ["*"] 
  }
  
  statement {
      sid = "EC2RestrictedTerminate"
      actions = ["ec2:TerminateInstances"]
      effect = "Allow"
      resources = ["*"]
      condition {
      test = "StringEquals"
      variable = "ec2:ResourceTag/Team"
      values = ["ap13"]
    }
    }

  statement {
  sid    = "IAMPassRole"
  actions = ["iam:PassRole"]
  effect    = "Allow"
  resources = [aws_iam_role.runner_role.arn]
}

  # VPC Access 
  statement {
    sid     = "VPCAccess"
    actions = [
      "ec2:CreateNetworkInterface",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DeleteNetworkInterface"
    ]
    effect = "Allow"
    resources = ["*"]
  }
  
  # SQS Permissions
  statement {
    sid = "SQSConsumption"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes"
    ]
    effect = "Allow"
    resources = [aws_sqs_queue.runner_queue.arn]
  }
}

resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_sqs_execution" {
  role = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaSQSQueueExecutionRole"
}

# Attach VPC access policy 
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
    effect = "Allow"
    resources = ["arn:aws:logs:*:*:log-group:/aws/ec2/github-runner:*"]
  }
  # Secrets Manager (to get GitHub App Credentials)
  statement {
    sid     = "SecretsManagerAccess"
    actions = ["secretsmanager:GetSecretValue", "kms:Decrypt"]
    effect = "Allow"
    resources = [data.aws_secretsmanager_secret.github_app.arn]
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
    sid     = "SQSSendMessage"
    actions = ["sqs:SendMessage"]
    effect = "Allow"
    resources = [aws_sqs_queue.runner_queue.arn]
  }
}

# Iam role and policies

# Lambda Execution Role
resource "aws_iam_role" "lambda_exec_role" {
  name               = "runner-manager-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role_doc.json
  tags = var.tags
}

resource "aws_iam_policy" "lambda_policy" {
  name   = "runner-manager-lambda-policy"
  policy = data.aws_iam_policy_document.lambda_policy_doc.json
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "lambda_attach_policy" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = aws_iam_policy.lambda_policy.arn
}


# EC2 Instance Profile Role
resource "aws_iam_role" "runner_role" {
  name               = "github-runner-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.runner_assume_role_doc.json
  tags = var.tags
}

resource "aws_iam_instance_profile" "runner_instance_profile" {
  name = "github-runner-instance-profile"
  role = aws_iam_role.runner_role.name
  tags = var.tags
}

resource "aws_iam_policy" "runner_policy" {
  name   = "github-runner-ec2-policy"
  policy = data.aws_iam_policy_document.runner_policy_doc.json
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "runner_attach_policy" {
  role       = aws_iam_role.runner_role.name
  policy_arn = aws_iam_policy.runner_policy.arn
}

# SSM Attachment 
resource "aws_iam_role_policy_attachment" "runner_attach_ssm" {
  role       = aws_iam_role.runner_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}


# 3. API Gateway IAM Role (to send messages to SQS)
resource "aws_iam_role" "apigw_sqs_role" {
  name               = "apigw-to-sqs-role"
  assume_role_policy = data.aws_iam_policy_document.apigw_sqs_assume_role_doc.json
  tags = var.tags
}

resource "aws_iam_policy" "apigw_sqs_policy" {
  name   = "apigw-sqs-send-message-policy"
  policy = data.aws_iam_policy_document.apigw_sqs_policy_doc.json
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "apigw_sqs_attach_policy" {
  role       = aws_iam_role.apigw_sqs_role.name
  policy_arn = aws_iam_policy.apigw_sqs_policy.arn
}
