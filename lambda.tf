# ─────────────────────────────────────────
# Package the Lambda function
# ─────────────────────────────────────────

data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/lambda/index.py"
  output_path = "${path.module}/lambda/runner_webhook.zip"
}

# ─────────────────────────────────────────
# IAM role for Lambda
# ─────────────────────────────────────────

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.project_name}-webhook-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-webhook-lambda-role"
  })
}

# Basic Lambda execution (CloudWatch Logs)
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Allow Lambda to launch EC2 instances from the Launch Template
data "aws_iam_policy_document" "lambda_ec2" {
  statement {
    sid    = "LaunchRunnerInstances"
    effect = "Allow"
    actions = [
      "ec2:RunInstances",
      "ec2:CreateTags",
      "ec2:DescribeInstances",
    ]
    resources = ["*"]
  }

  # Allow passing the runner IAM instance profile to new instances
  statement {
    sid     = "PassInstanceProfile"
    effect  = "Allow"
    actions = ["iam:PassRole"]
    resources = [
      aws_iam_role.runner.arn,
      aws_iam_instance_profile.runner.arn,
    ]
  }
}

resource "aws_iam_role_policy" "lambda_ec2" {
  name   = "launch-runner-instances"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_ec2.json
}

# ─────────────────────────────────────────
# Lambda function
# ─────────────────────────────────────────

resource "aws_lambda_function" "webhook" {
  function_name    = "${var.project_name}-runner-webhook"
  role             = aws_iam_role.lambda.arn
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  handler          = "index.handler"
  runtime          = "python3.12"
  timeout          = 30

  environment {
    variables = {
      LAUNCH_TEMPLATE_ID      = aws_launch_template.runner.id
      LAUNCH_TEMPLATE_VERSION = "$Latest"
      INSTANCE_TYPE           = var.ubuntu_instance_type
      WEBHOOK_SECRET          = var.github_webhook_secret
      RUNNER_NAME_PREFIX      = var.github_runner_name_prefix
    }
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-runner-webhook"
  })
}

# ─────────────────────────────────────────
# API Gateway (HTTP API – cheaper & simpler)
# ─────────────────────────────────────────

resource "aws_apigatewayv2_api" "webhook" {
  name          = "${var.project_name}-runner-webhook"
  protocol_type = "HTTP"

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-runner-webhook"
  })
}

resource "aws_apigatewayv2_integration" "webhook" {
  api_id                 = aws_apigatewayv2_api.webhook.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.webhook.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "webhook" {
  api_id    = aws_apigatewayv2_api.webhook.id
  route_key = "POST /webhook"
  target    = "integrations/${aws_apigatewayv2_integration.webhook.id}"
}

resource "aws_apigatewayv2_stage" "webhook" {
  api_id      = aws_apigatewayv2_api.webhook.id
  name        = "$default"
  auto_deploy = true

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-runner-webhook-stage"
  })
}

# Allow API Gateway to invoke the Lambda
resource "aws_lambda_permission" "webhook" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.webhook.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.webhook.execution_arn}/*/*"
}
