# Create Subnet
resource "aws_subnet" "exit_node" {
  vpc_id            = var.vpc_id
  cidr_block        = var.subnet_cidr
  availability_zone = var.availability_zone
  tags = {
    Name = "headscale-exit-node"
  }
}

# # Create NACL for Subnet
resource "aws_network_acl" "exit_node" {
  vpc_id = var.vpc_id
  egress {
    protocol   = "tcp"
    rule_no    = 100
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 65535
  }

  egress {
    protocol   = "udp"
    rule_no    = 101
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
  egress {
    protocol        = "udp"
    rule_no         = 201
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
    protocol   = "udp"
    rule_no    = 301
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
  ingress {
    protocol        = "udp"
    rule_no         = 401
    action          = "allow"
    ipv6_cidr_block = "::/0"
    from_port       = 0
    to_port         = 65535
  }
  tags = {
    Name = "headscale"
  }
}
resource "aws_network_acl_association" "exit_node" {
  network_acl_id = aws_network_acl.exit_node.id
  subnet_id      = aws_subnet.exit_node.id
}

# Create Route Table for Subnet
resource "aws_route_table" "exit_node" {
  vpc_id = var.vpc_id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = var.gateway_id
  }
  tags = {
    Name = "headscale-exit-node"
  }
}

# Associate Route Table with Subnet
resource "aws_route_table_association" "exit_node" {
  subnet_id      = aws_subnet.exit_node.id
  route_table_id = aws_route_table.exit_node.id
}
