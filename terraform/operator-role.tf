# Lokaler Terraform-Operator – Einstieg mit Leserechten.
# Bootstrap bleibt beim IAM-User cloud_user.

data "aws_iam_policy_document" "operator_trust" {
  statement {
    sid     = "AllowCloudUser"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type = "AWS"
      identifiers = [
        "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/cloud_user"
      ]
    }
  }
}

resource "aws_iam_role" "operator" {
  name               = "Terraform-Operator-Role"
  assume_role_policy = data.aws_iam_policy_document.operator_trust.json

  max_session_duration = 3600

  tags = {
    Project = "cicd-lab"
    Purpose = "terraform-operator"
  }
}

resource "aws_iam_role_policy" "operator_readonly" {
  name = "Terraform-Operator-ReadOnly"
  role = aws_iam_role.operator.id

  policy = aws_iam_role_policy.terraform_plan_readonly.policy
}
