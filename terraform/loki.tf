locals {
  loki_lambda_name = "cicd-lab-loki-forwarder"
  loki_release     = jsondecode(file("${path.module}/loki-lambda-release.json"))
  loki_token_arn   = "arn:aws:ssm:us-east-1:${data.aws_caller_identity.current.account_id}:parameter/cicd-lab/grafana/loki-token"
}

resource "aws_cloudwatch_log_group" "loki_forwarder" {
  name              = "/aws/lambda/${local.loki_lambda_name}"
  retention_in_days = 7
  tags              = local.ecs_tags
}

resource "aws_iam_role" "loki_forwarder" {
  name = local.loki_lambda_name
  tags = local.ecs_tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "loki_forwarder" {
  name = "ReadLokiTokenAndWriteFunctionLogs"
  role = aws_iam_role.loki_forwarder.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = local.loki_token_arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.loki_forwarder.arn}:log-stream:*"
      }
    ]
  })
}

resource "aws_lambda_function" "loki_forwarder" {
  function_name    = local.loki_lambda_name
  role             = aws_iam_role.loki_forwarder.arn
  runtime          = "provided.al2023"
  handler          = "bootstrap"
  architectures    = ["x86_64"]
  filename         = "${path.module}/.terraform/lambda-promtail.zip"
  source_code_hash = local.loki_release.sha256_base64
  timeout          = 30
  memory_size      = 128
  tags             = local.ecs_tags

  environment {
    variables = {
      WRITE_ADDRESS            = "https://logs-prod-050-prod-eu-west-4.grafana.net/loki/api/v1/push"
      USERNAME                 = "1876602"
      PASSWORD                 = local.loki_token_arn
      PRINT_LOG_LINE           = "false"
      EXTRA_LABELS             = "app,cicd-webserver,platform,fargate"
      OMIT_EXTRA_LABELS_PREFIX = "true"
    }
  }

  depends_on = [aws_iam_role_policy.loki_forwarder]
}

resource "aws_lambda_permission" "ecs_logs" {
  statement_id   = "AllowECSCloudWatchLogs"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.loki_forwarder.function_name
  principal      = "logs.us-east-1.amazonaws.com"
  source_arn     = "${aws_cloudwatch_log_group.ecs_web.arn}:*"
  source_account = data.aws_caller_identity.current.account_id
}

resource "aws_cloudwatch_log_subscription_filter" "ecs_to_loki" {
  name            = "grafana-loki"
  log_group_name  = aws_cloudwatch_log_group.ecs_web.name
  filter_pattern  = ""
  destination_arn = aws_lambda_function.loki_forwarder.arn

  depends_on = [aws_lambda_permission.ecs_logs]
}
