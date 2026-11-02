# OIDC-Vertrauensrichtlinie fuer Terraform Apply
data "aws_iam_policy_document" "terraform_apply_trust" {
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
        "repo:paololaspina@323260101/project@1434775201:environment:terraform-apply"
      ]
    }
  }
}

# Separate IAM-Rolle fuer Terraform Apply
resource "aws_iam_role" "terraform_apply" {
  name               = "GitHubActions-Terraform-Apply-Role"
  assume_role_policy = data.aws_iam_policy_document.terraform_apply_trust.json

  tags = {
    Project = "cicd-lab"
    Purpose = "terraform-apply"
  }
}

# Bestehende Terraform-Leseberechtigungen wiederverwenden
resource "aws_iam_role_policy" "terraform_apply_readonly" {
  name = "Terraform-Apply-ReadOnly"
  role = aws_iam_role.terraform_apply.id

  policy = aws_iam_role_policy.terraform_plan_readonly.policy
}

# Zugriff auf den Terraform Remote State
resource "aws_iam_role_policy" "terraform_apply_state" {
  name = "Terraform-Apply-State"
  role = aws_iam_role.terraform_apply.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
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
          "s3:GetObject",
          "s3:PutObject"
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

# Bestehende Terraform-Leseberechtigungen wiederverwenden
