mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = { names = ["us-east-1a", "us-east-1b"] }
  }

  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = jsonencode({
        Version   = "2012-10-17"
        Statement = []
      })
    }
  }

  mock_data "aws_ssm_parameter" {
    defaults = { value = "ami-0123456789abcdef0" }
  }

  mock_resource "aws_ecr_repository" {
    defaults = { repository_url = "123456789012.dkr.ecr.us-east-1.amazonaws.com/cicd-webserver" }
  }
}

run "empty_ecr_bootstrap" {
  command = plan

  assert {
    condition     = aws_ecs_service.web.desired_count == 0
    error_message = "The service must wait for a published image before starting a task."
  }

  assert {
    condition     = aws_ecs_service.web.launch_type == "FARGATE" && aws_ecs_service.web.network_configuration[0].assign_public_ip
    error_message = "The lab website needs Fargate and a public IP."
  }

  assert {
    condition     = aws_ecs_task_definition.web_template.network_mode == "awsvpc"
    error_message = "Fargate requires awsvpc."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.ecs_http.from_port == 80 && aws_vpc_security_group_ingress_rule.ecs_http.to_port == 80
    error_message = "The Fargate website accepts HTTP on port 80."
  }

  assert {
    condition     = aws_instance.web.instance_type == "t3.micro" && aws_ecr_repository.web.image_tag_mutability == "IMMUTABLE"
    error_message = "Keep the EC2 webserver and immutable ECR tags."
  }
}

run "two_ec2_targets_behind_alb" {
  command = plan

  assert {
    condition     = data.aws_subnet.default.availability_zone != data.aws_subnet.secondary.availability_zone
    error_message = "Use two different Availability Zones for the public ALB."
  }

  assert {
    condition     = length(aws_lb_target_group_attachment.web) == 2 && aws_lb_listener.http.port == 80
    error_message = "Both EC2 instances must be registered with the HTTP load balancer."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.ec2_from_alb.cidr_ipv4 == null
    error_message = "EC2 HTTP ingress must come from the ALB security group."
  }
}
