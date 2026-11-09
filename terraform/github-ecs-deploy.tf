locals {
  ecs_arn_prefix = "arn:aws:ecs:us-east-1:${data.aws_caller_identity.current.account_id}"
  ecs_family_arn = "${local.ecs_arn_prefix}:task-definition/${local.ecs_name}:*"
}

resource "aws_iam_role" "github_ecs_deploy" {
  name               = "GitHubActions-ECS-Deploy-Role"
  assume_role_policy = data.aws_iam_policy_document.github_oidc_trust.json
  tags               = local.ecs_tags
}

resource "aws_iam_role_policy" "github_ecs_deploy" {
  name = "GitHubActions-ECS-Deploy"
  role = aws_iam_role.github_ecs_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ecs:RegisterTaskDefinition"
        Resource = local.ecs_family_arn
      },
      {
        Effect   = "Allow"
        Action   = "ecs:UpdateService"
        Resource = aws_ecs_service.web.id
        Condition = {
          ArnLike = { "ecs:task-definition" = local.ecs_family_arn }
        }
      },
      {
        Effect   = "Allow"
        Action   = "ecs:DescribeServices"
        Resource = aws_ecs_service.web.id
      },
      {
        Effect   = "Allow"
        Action   = "ecs:ListTasks"
        Resource = "*"
        Condition = {
          ArnEquals = { "ecs:cluster" = aws_ecs_cluster.web.arn }
        }
      },
      {
        Effect   = "Allow"
        Action   = "ecs:DescribeTasks"
        Resource = "${local.ecs_arn_prefix}:task/${local.ecs_name}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["ecs:DescribeTaskDefinition", "ec2:DescribeNetworkInterfaces"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.ecs_execution.arn
        Condition = {
          StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" }
        }
      }
    ]
  })
}
