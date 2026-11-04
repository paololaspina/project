# Eingeschraenkte Infrastruktur-Schreibrechte fuer GitHub Terraform Apply.
# Keine IAM-Schreibrechte und kein iam:PassRole.

resource "aws_iam_role_policy" "terraform_apply_write" {
  name = "Terraform-Apply-Infrastructure-Write"
  role = aws_iam_role.terraform_apply.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ManageLabDashboard"
        Effect = "Allow"
        Action = [
          "cloudwatch:PutDashboard",
          "cloudwatch:DeleteDashboards"
        ]
        Resource = "arn:aws:cloudwatch::${data.aws_caller_identity.current.account_id}:dashboard/cicd-lab-monitoring"
      },
      {
        Sid    = "ManageLabAlarms"
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricAlarm",
          "cloudwatch:DeleteAlarms"
        ]
        Resource = [
          "arn:aws:cloudwatch:us-east-1:${data.aws_caller_identity.current.account_id}:alarm:cicd-webserver-cpu-high",
          "arn:aws:cloudwatch:us-east-1:${data.aws_caller_identity.current.account_id}:alarm:cicd-webserver-status-failed"
        ]
      },
      {
        Sid    = "ManageLabECRSettings"
        Effect = "Allow"
        Action = [
          "ecr:PutImageScanningConfiguration",
          "ecr:PutImageTagMutability"
        ]
        Resource = aws_ecr_repository.web.arn
      },
      {
        Sid    = "ManageLabSecurityGroupRules"
        Effect = "Allow"
        Action = [
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:AuthorizeSecurityGroupEgress",
          "ec2:RevokeSecurityGroupEgress"
        ]
        Resource = aws_security_group.web.arn

        Condition = {
          StringEquals = {
            "aws:ResourceTag/Project" = "cicd-lab"
          }
        }
      }
    ]
  })
}
