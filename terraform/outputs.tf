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
