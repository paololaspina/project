# Aktuelles Amazon Linux 2023 AMI automatisch ermitteln
data "aws_ssm_parameter" "amazon_linux" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# EC2-Instanz für unsere CI/CD-Webseite
resource "aws_instance" "web" {
  ami           = data.aws_ssm_parameter.amazon_linux.value
  instance_type = "t3.micro"

  subnet_id                   = data.aws_subnet.default.id
  associate_public_ip_address = true

  vpc_security_group_ids = [
    aws_security_group.web.id
  ]

  iam_instance_profile = aws_iam_instance_profile.ec2.name

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    dnf install -y docker
    systemctl enable --now docker
  EOF

  root_block_device {
    volume_size = 10
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name    = "cicd-webserver"
    Project = "cicd-lab"
  }
}
