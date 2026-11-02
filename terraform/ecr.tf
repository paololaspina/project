
# Docker-Repository für unsere CI/CD-Pipeline
resource "aws_ecr_repository" "web" {
  name                 = "cicd-webserver"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Project = "cicd-lab"
  }
}
