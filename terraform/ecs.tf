locals {
  ecs_name = "cicd-webserver"
  ecs_tags = { Project = "cicd-lab" }
}

resource "aws_ecs_cluster" "web" {
  name = local.ecs_name
  tags = local.ecs_tags
}

resource "aws_cloudwatch_log_group" "ecs_web" {
  name              = "/ecs/${local.ecs_name}"
  retention_in_days = 7
  tags              = local.ecs_tags
}

resource "aws_security_group" "ecs_web" {
  name        = "cicd-fargate-web"
  description = "HTTP for the Fargate lab website"
  vpc_id      = data.aws_vpc.default.id
  tags        = local.ecs_tags
}

resource "aws_vpc_security_group_ingress_rule" "ecs_http" {
  security_group_id = aws_security_group.ecs_web.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "ecs_https" {
  security_group_id = aws_security_group.ecs_web.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_iam_role" "ecs_execution" {
  name = "cicd-fargate-execution"
  tags = local.ecs_tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "ecs_execution" {
  name = "PullWebImageAndWriteLogs"
  role = aws_iam_role.ecs_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
        Resource = aws_ecr_repository.web.arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.ecs_web.arn}:log-stream:web/nginx/*"
      }
    ]
  })
}

# This template has its own family so CI always reads the Terraform-managed
# configuration. The placeholder image is never started.
resource "aws_ecs_task_definition" "web_template" {
  family                   = "${local.ecs_name}-template"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  tags                     = local.ecs_tags

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name         = "nginx"
    image        = "${aws_ecr_repository.web.repository_url}:bootstrap"
    essential    = true
    portMappings = [{ containerPort = 80, protocol = "tcp" }]
    healthCheck = {
      command     = ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1/"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 10
    }
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.ecs_web.name
        awslogs-region        = "us-east-1"
        awslogs-stream-prefix = "web"
      }
    }
  }])
}

resource "aws_ecs_service" "web" {
  name            = local.ecs_name
  cluster         = aws_ecs_cluster.web.id
  task_definition = aws_ecs_task_definition.web_template.arn
  launch_type     = "FARGATE"
  desired_count   = 0
  tags            = local.ecs_tags

  network_configuration {
    subnets          = [data.aws_subnet.default.id]
    security_groups  = [aws_security_group.ecs_web.id]
    assign_public_ip = true
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = false
  }

  # CI activates one task with a published image. Later applies preserve it.
  lifecycle {
    ignore_changes = [desired_count, task_definition]
  }

  depends_on = [aws_iam_role_policy.ecs_execution]
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.web.name
}

output "ecs_service_name" {
  value = aws_ecs_service.web.name
}
