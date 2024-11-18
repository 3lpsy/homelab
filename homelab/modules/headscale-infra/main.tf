

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
  egress {
    protocol        = "tcp"
    rule_no         = 200
    action          = "allow"
    ipv6_cidr_block = "::/0"
    from_port       = 0
    to_port         = 65535
  }
  ingress {
    protocol   = "tcp"
    rule_no    = 300
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 65535
  }

  ingress {
    protocol        = "tcp"
    rule_no         = 400
    action          = "allow"
    ipv6_cidr_block = "::/0"
    from_port       = 0
    to_port         = 65535
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


resource "aws_eip" "main" {
  instance = aws_instance.main.id
  domain   = "vpc"
  tags = {
    Name = "headscale"
  }
  depends_on = [aws_internet_gateway.main]
}


# Backup
resource "aws_s3_bucket" "main" {
  bucket = var.backup_bucket_name # Replace with a unique bucket name
  tags = {
    Name = var.backup_bucket_name
  }
}
resource "aws_s3_bucket_ownership_controls" "main" {
  bucket = aws_s3_bucket.main.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}
resource "aws_s3_bucket_acl" "main" {
  depends_on = [aws_s3_bucket_ownership_controls.main]

  bucket = aws_s3_bucket.main.id
  acl    = "private"
}

# IAM Role for EC2 instance
resource "aws_iam_role" "main" {
  name               = "homelab-headscale-s3-append"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      }
    }
  ]
}
EOF
}

# Attach policy to IAM Role
resource "aws_iam_role_policy" "main" {
  name = "homelab-headscale-s3-append"
  role = aws_iam_role.main.id

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:PutObjectAcl",
        "s3:GetObjectAcl"
      ],
      "Resource": "${aws_s3_bucket.main.arn}/headscale/*"
    }
  ]
}
EOF
}
resource "aws_iam_instance_profile" "main" {
  name = aws_iam_role.main.name
  role = aws_iam_role.main.name
}


resource "aws_instance" "main" {
  ami                    = var.ami
  instance_type          = var.instance_type
  vpc_security_group_ids = [aws_security_group.main.id]
  subnet_id              = aws_subnet.main.id
  iam_instance_profile   = aws_iam_instance_profile.main.name
  user_data              = <<-EOF
    #!/bin/bash
    mkdir -p /home/${var.ec2_user}/.ssh
    echo "${var.ssh_pub_key}" >> /home/${var.ec2_user}/.ssh/authorized_keys
    chown -R ${var.ec2_user}:${var.ec2_user} /home/${var.ec2_user}/.ssh
    chmod 600 /home/${var.ec2_user}/.ssh/authorized_keys
    sudo timedatectl set-ntp 1
    sudo timedatectl set-timezone America/Chicago
  EOF
  tags = {
    Name = "headscale"
  }
}
