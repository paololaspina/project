output "ec2_instance_id" {
  description = "ID unserer EC2-Instanz"
  value       = aws_instance.web.id
}

output "ec2_public_ip" {
  description = "Oeffentliche IPv4-Adresse unseres Webservers"
  value       = aws_instance.web.public_ip
}

output "website_url" {
  description = "HTTP-Adresse unserer Webseite"
  value       = "http://${aws_instance.web.public_ip}"
}


# Aktuelle AWS-Account-ID
data "aws_caller_identity" "current" {}

output "aws_account_id" {
  description = "AWS-Account der aktuellen Sandbox"
  value       = data.aws_caller_identity.current.account_id
}

# Aktuelle Netzwerkressourcen
output "vpc_id" {
  description = "Automatisch erkannte VPC"
  value       = data.aws_vpc.default.id
}

output "subnet_id" {
  description = "Automatisch erkanntes Subnetz"
  value       = data.aws_subnet.default.id
}

# CloudWatch-Dashboard
output "cloudwatch_dashboard_url" {
  description = "CloudWatch-Monitoring der aktuellen Sandbox"
  value       = "https://${data.aws_caller_identity.current.account_id}.console.aws.amazon.com/cloudwatch/home?region=us-east-1#dashboards/dashboard/${aws_cloudwatch_dashboard.cicd.dashboard_name}"
}

# ECR-Repository-Adresse für unsere CI/CD-Pipeline
output "ecr_repository_url" {
  description = "Docker-Repository fuer unsere CI/CD-Pipeline"
  value       = aws_ecr_repository.web.repository_url
}
