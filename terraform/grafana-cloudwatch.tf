locals {
  grafana_cloudwatch = jsondecode(file("${path.module}/grafana-cloudwatch.json"))
}

resource "aws_iam_role" "grafana_cloudwatch" {
  name = "GrafanaCloudWatchReadOnly"
  tags = { Project = "cicd-lab" }

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        AWS = "arn:aws:iam::${local.grafana_cloudwatch.grafana_aws_account_id}:root"
      }
      Action = "sts:AssumeRole"
      Condition = {
        StringEquals = { "sts:ExternalId" = local.grafana_cloudwatch.external_id }
      }
    }]
  })
}

resource "aws_iam_role_policy" "grafana_cloudwatch" {
  name = "ReadLabCloudWatch"
  role = aws_iam_role.grafana_cloudwatch.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadMetricsAndDiscoverLogGroups"
        Effect = "Allow"
        Action = [
          "cloudwatch:GetMetricData",
          "cloudwatch:ListMetrics",
          "logs:DescribeLogGroups",
          "logs:ListAggregateLogGroupSummaries",
          "logs:GetQueryResults",
          "logs:StopQuery"
        ]
        Resource = "*"
        Condition = {
          StringEquals = { "aws:RequestedRegion" = "us-east-1" }
        }
      },
      {
        Sid      = "QueryFargateLogs"
        Effect   = "Allow"
        Action   = ["logs:StartQuery", "logs:GetLogGroupFields"]
        Resource = aws_cloudwatch_log_group.ecs_web.arn
      }
    ]
  })
}

output "grafana_cloudwatch_role_arn" {
  description = "AWS IAM role ARN for the Grafana CloudWatch data source"
  value       = aws_iam_role.grafana_cloudwatch.arn
}
