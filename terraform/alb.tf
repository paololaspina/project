resource "aws_security_group" "alb" {
  name        = "cicd-lab-alb"
  description = "Public HTTP entry point for the lab"
  vpc_id      = data.aws_vpc.default.id
  tags        = local.ecs_tags
}

resource "aws_security_group" "ec2_backend" {
  name        = "cicd-lab-ec2-backend"
  description = "EC2 web targets behind the lab ALB"
  vpc_id      = data.aws_vpc.default.id
  tags        = local.ecs_tags
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_egress_rule" "alb_to_ec2" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.ec2_backend.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
}

resource "aws_vpc_security_group_ingress_rule" "ec2_from_alb" {
  security_group_id            = aws_security_group.ec2_backend.id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
}

resource "aws_vpc_security_group_egress_rule" "ec2_https" {
  security_group_id = aws_security_group.ec2_backend.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_lb" "web" {
  name               = "cicd-lab-web"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = [data.aws_subnet.default.id, data.aws_subnet.secondary.id]
  tags               = local.ecs_tags
}

resource "aws_lb_target_group" "web" {
  name        = "cicd-lab-web"
  target_type = "instance"
  protocol    = "HTTP"
  port        = 80
  vpc_id      = data.aws_vpc.default.id
  tags        = local.ecs_tags

  health_check {
    path                = "/"
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.web.arn
  protocol          = "HTTP"
  port              = 80
  tags              = local.ecs_tags

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

resource "aws_lb_target_group_attachment" "web" {
  for_each = {
    primary   = aws_instance.web.id
    secondary = aws_instance.web_secondary.id
  }

  target_group_arn = aws_lb_target_group.web.arn
  target_id        = each.value
  port             = 80
}
