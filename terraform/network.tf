# Standard-VPC des aktuellen AWS-Accounts ermitteln
data "aws_vpc" "default" {
  default = true
}

# Verfügbare Availability Zones ermitteln
data "aws_availability_zones" "available" {
  state = "available"
}

# Standardsubnetz der ersten Availability Zone
data "aws_subnet" "default" {
  vpc_id            = data.aws_vpc.default.id
  availability_zone = data.aws_availability_zones.available.names[0]
  default_for_az    = true
}
