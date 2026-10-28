resource "aws_security_group" "web" {
  name_prefix = "cicd-web-"
  description = "Security Group fuer unsere CI/CD-Webseite"
  vpc_id      = "vpc-0ad96a05d2c73c196"

  tags = {
    Name    = "cicd-web-sg"
    Project = "cicd-lab"
  }
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.web.id

  description = "HTTP-Zugriff auf unsere Webseite"
  cidr_ipv4   = "0.0.0.0/0"
  from_port   = 80
  to_port     = 80
  ip_protocol = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.web.id

  description = "HTTPS fuer Updates und AWS-Dienste"
  cidr_ipv4   = "0.0.0.0/0"
  from_port   = 443
  to_port     = 443
  ip_protocol = "tcp"
}
