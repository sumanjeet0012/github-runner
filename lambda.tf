# ─────────────────────────────────────────
# Package the Lambda functions
# ─────────────────────────────────────────

data "archive_file" "lambda" {
  type        = "zip"
  output_path = "${path.module}/lambda/runner_webhook.zip"
  source_dir  = "${path.module}/lambda"
  excludes    = ["runner_webhook.zip"]
}

# ─────────────────────────────────────────
# SQS – job queue + dead-letter queue
# ─────────────────────────────────────────

resource "aws_sqs_queue" "runner_dlq" {
  name                       = "${var.project_name}-runner-dlq"
  message_retention_seconds  = 1209600 # 14 days - inspect truly broken messages
  visibility_timeout_seconds = 60

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-runner-dlq"
  })
}

resource "aws_sqs_queue" "runner_jobs" {
  name = "${var.project_name}-runner-jobs"

  # 5 minutes: when pool is full the message becomes invisible for this long
  # before SQS retries it - gives running jobs time to complete and free a slot.
  visibility_timeout_seconds = 300
  message_retention_seconds  = 86400 # 24 hours - matches GitHub's queued job TTL

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.runner_dlq.arn
    # Only DLQ after 1000 retries - effectively only for truly unprocessable
    # messages (bad JSON etc.), never for pool-full conditions.
    # At 5 min backoff x 1000 = ~83 hours >> 24h message retention,
    # so a job will expire naturally before ever hitting the DLQ.
    maxReceiveCount = 1000
  })

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-runner-jobs"
  })
}

# ─────────────────────────────────────────
# DynamoDB – runner pool state counter
# ─────────────────────────────────────────

resource "aws_dynamodb_table" "runner_pool" {
  name         = "${var.project_name}-runner-pool"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"

  attribute {
    name = "pk"
    type = "S"
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-runner-pool"
  })
}

# Seed the counter row so it always exists
resource "aws_dynamodb_table_item" "runner_pool_counter" {
  table_name = aws_dynamodb_table.runner_pool.name
  hash_key   = aws_dynamodb_table.runner_pool.hash_key

  item = jsonencode({
    pk            = { S = "pool" }
    active_count  = { N = "0" }
  })

  lifecycle {
    # Never overwrite after initial creation – Lambda owns this value
    ignore_changes = [item]
  }
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

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "lambda_permissions" {
  # Launch EC2 instances
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

  # Pass the runner IAM role to new instances
  statement {
    sid     = "PassInstanceProfile"
    effect  = "Allow"
    actions = ["iam:PassRole"]
    resources = [
      aws_iam_role.runner.arn,
      aws_iam_instance_profile.runner.arn,
    ]
  }

  # Read/write the SQS job queue
  statement {
    sid    = "SQSJobQueue"
    effect = "Allow"
    actions = [
      "sqs:SendMessage",
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
    ]
    resources = [
      aws_sqs_queue.runner_jobs.arn,
      aws_sqs_queue.runner_dlq.arn,
    ]
  }

  # Atomic counter in DynamoDB
  statement {
    sid    = "DynamoDBPoolState"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:UpdateItem",
      "dynamodb:PutItem",
    ]
    resources = [aws_dynamodb_table.runner_pool.arn]
  }
}

resource "aws_iam_role_policy" "lambda_permissions" {
  name   = "runner-lambda-permissions"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_permissions.json
}

# ─────────────────────────────────────────
# Lambda 1: Webhook receiver
# Receives GitHub webhook → validates HMAC → enqueues to SQS
# Fast, lightweight – returns 200 to GitHub immediately
# ─────────────────────────────────────────

resource "aws_lambda_function" "webhook" {
  function_name    = "${var.project_name}-runner-webhook"
  role             = aws_iam_role.lambda.arn
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  handler          = "index.handler"
  runtime          = "python3.12"
  timeout          = 10  # webhook receiver must be fast

  environment {
    variables = {
      WEBHOOK_SECRET  = var.github_webhook_secret
      JOB_QUEUE_URL   = aws_sqs_queue.runner_jobs.url
    }
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-runner-webhook"
  })
}

# ─────────────────────────────────────────
# Lambda 2: Job processor
# Triggered by SQS – manages pool, launches EC2
# ─────────────────────────────────────────

resource "aws_lambda_function" "processor" {
  function_name    = "${var.project_name}-runner-processor"
  role             = aws_iam_role.lambda.arn
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  handler          = "processor.handler"
  runtime          = "python3.12"
  # Must be < SQS visibility_timeout (300s). 30s is plenty - just DynamoDB + EC2 API calls.
  timeout          = 30

  environment {
    variables = {
      LAUNCH_TEMPLATE_ID         = aws_launch_template.runner.id
      LAUNCH_TEMPLATE_ID_WINDOWS = aws_launch_template.runner_windows.id
      LAUNCH_TEMPLATE_VERSION    = "$Latest"
      INSTANCE_TYPE              = var.ubuntu_instance_type
      RUNNER_NAME_PREFIX         = var.github_runner_name_prefix
      MAX_POOL_SIZE              = tostring(var.runner_max_pool_size)
      DYNAMODB_TABLE             = aws_dynamodb_table.runner_pool.name
      JOB_QUEUE_URL              = aws_sqs_queue.runner_jobs.url
    }
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-runner-processor"
  })
}

# SQS triggers the processor Lambda (batch size 1 = one job per invocation)
resource "aws_lambda_event_source_mapping" "sqs_to_processor" {
  event_source_arn = aws_sqs_queue.runner_jobs.arn
  function_name    = aws_lambda_function.processor.arn
  batch_size       = 1
  # Small batching window reduces thundering-herd when many jobs arrive at once,
  # giving the DynamoDB counter time to settle between launches.
  maximum_batching_window_in_seconds = 5
  enabled                            = true
}

# Allow SQS to invoke the processor Lambda
resource "aws_lambda_permission" "sqs_invoke_processor" {
  statement_id  = "AllowSQSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.processor.function_name
  principal     = "sqs.amazonaws.com"
  source_arn    = aws_sqs_queue.runner_jobs.arn
}

# ─────────────────────────────────────────
# API Gateway (HTTP API)
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

resource "aws_lambda_permission" "webhook" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.webhook.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.webhook.execution_arn}/*/*"
}
