# Separate OIDC-Rolle fuer Terraform-Plan
data "aws_iam_policy_document" "terraform_plan_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type = "Federated"
      identifiers = [
        aws_iam_openid_connect_provider.github.arn
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:paololaspina@323260101/project@1434775201:ref:refs/heads/main"
      ]
    }
  }
}

resource "aws_iam_role" "terraform_plan" {
  name               = "GitHubActions-Terraform-Plan-Role"
  assume_role_policy = data.aws_iam_policy_document.terraform_plan_trust.json

  tags = {
    Project = "cicd-lab"
    Purpose = "terraform-plan"
  }
}

# AWS-Ressourcen ausschliesslich lesen
resource "aws_iam_role_policy" "terraform_plan_readonly" {
  name = "Terraform-Plan-ReadOnly"
  role = aws_iam_role.terraform_plan.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:Describe*",
          "elasticloadbalancing:DescribeListeners",
          "elasticloadbalancing:DescribeLoadBalancers",
          "elasticloadbalancing:DescribeLoadBalancerAttributes",
          "elasticloadbalancing:DescribeTags",
          "elasticloadbalancing:DescribeTargetGroups",
          "elasticloadbalancing:DescribeTargetGroupAttributes",
          "elasticloadbalancing:DescribeTargetHealth",
          "ecs:DescribeClusters",
          "ecs:DescribeServices",
          "ecs:DescribeTaskDefinition",
          "ecs:ListTagsForResource",
          "logs:DescribeLogGroups",
          "logs:DescribeSubscriptionFilters",
          "logs:ListTagsForResource",
          "iam:GetRole",
          "iam:GetRolePolicy",
          "iam:GetInstanceProfile",
          "iam:GetOpenIDConnectProvider",
          "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies",
          "iam:ListInstanceProfilesForRole",
          "iam:ListRoleTags",
          "ecr:DescribeRepositories",
          "ecr:ListTagsForResource",
          "cloudwatch:DescribeAlarms",
          "cloudwatch:ListTagsForResource",
          "cloudwatch:GetDashboard",
          "sns:GetTopicAttributes",
          "sns:ListTagsForResource",
          "ssm:GetParameter",
          "sts:GetCallerIdentity"
        ]
        Resource = "*"
      },
      {
        Effect   = "Deny"
        Action   = "ssm:GetParameter"
        Resource = local.loki_token_arn
      },
      {
        Effect = "Allow"
        Action = [
          "lambda:GetFunction",
          "lambda:GetFunctionCodeSigningConfig",
          "lambda:GetPolicy",
          "lambda:ListTags",
          "lambda:ListVersionsByFunction"
        ]
        Resource = "arn:aws:lambda:us-east-1:${data.aws_caller_identity.current.account_id}:function:${local.loki_lambda_name}"
      }
    ]
  })
}

# Zugriff auf das Terraform S3-Backend
resource "aws_iam_role_policy" "terraform_plan_state" {
  name = "Terraform-State-Access"
  role = aws_iam_role.terraform_plan.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket"
        ]
        Resource = "arn:aws:s3:::cicd-terraform-state-${data.aws_caller_identity.current.account_id}"
        Condition = {
          StringLike = {
            "s3:prefix" = [
              "cicd-webserver/terraform.tfstate"
            ]
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject"
        ]
        Resource = "arn:aws:s3:::cicd-terraform-state-${data.aws_caller_identity.current.account_id}/cicd-webserver/terraform.tfstate"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = "arn:aws:s3:::cicd-terraform-state-${data.aws_caller_identity.current.account_id}/cicd-webserver/terraform.tfstate.tflock"
      }
    ]
  })
}
