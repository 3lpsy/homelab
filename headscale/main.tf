terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Configure the AWS Provider
provider "aws" {
  region     = var.aws_region
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key
}

# Create VPC
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  tags = {
    Name = "headscale"
  }
}

# Create Subnet
resource "aws_subnet" "main" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.0.0/24"
  availability_zone = "us-east-1e"

  tags = {
    Name = "headscale"
  }
}

# resource "aws_network_interface" "main" {
#   subnet_id       = aws_subnet.main.id
#   private_ips     = ["10.0.0.209"]
#   security_groups = []

# }

# # Create NACL for Subnet
resource "aws_network_acl" "main" {
  vpc_id = aws_vpc.main.id

  egress {
    protocol   = "tcp"
    rule_no    = 100
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 65535
  }

  ingress {
    protocol   = "tcp"
    rule_no    = 200
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 443
    to_port    = 443
  }
  ingress {
    protocol   = "tcp"
    rule_no    = 300
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 22
    to_port    = 22
  }

  tags = {
    Name = "headscale"
  }
}

resource "aws_network_acl_association" "main" {
  network_acl_id = aws_network_acl.main.id
  subnet_id      = aws_subnet.main.id
}



# Create Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "headscale"
  }
}

# # Associate Internet Gateway with VPC
# resource "aws_internet_gateway_attachment" "main" {
#   vpc_id              = aws_vpc.main.id
#   internet_gateway_id = aws_internet_gateway.main.id
# }

# Create Route Table for Subnet
resource "aws_route_table" "main" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = {
    Name = "headscale"
  }
}

# Associate Route Table with Subnet
resource "aws_route_table_association" "main" {
  subnet_id      = aws_subnet.main.id
  route_table_id = aws_route_table.main.id
}
#
# Create Security Group for EC2 Instance
resource "aws_security_group" "main" {
  name        = "headscale"
  description = "Allow inbound traffic on ssh and https"
  vpc_id      = aws_vpc.main.id
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }


  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Create EC2 Instance
resource "aws_instance" "main" {
  ami           = "ami-0557a15b87f6559cf"
  instance_type = "t2.micro"

  vpc_security_group_ids = [aws_security_group.main.id]
  subnet_id              = aws_subnet.main.id

  tags = {
    Name = "headscale"
  }
}
