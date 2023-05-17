terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      "Environment" = "sos-${terraform.workspace}"
      "ManagedBy"   = "terraform"
    }
  }
}


locals {  
  vpc_base_cidr = cidrsubnet(var.base_cidr, 4, 0)
  
  public_cidr_blocks = { for i in range(1, 3) :
  data.aws_availability_zones.available.names[i % 2] => cidrsubnet(var.base_cidr, 4, i) }
  private_cidr_blocks = { for i in range(0, 2) :
  data.aws_availability_zones.available.names[i % 2] => cidrsubnet(var.sos_cidr, 1, i) }
}

data "aws_availability_zones" "available" {
  state = "available"
}

# VPC Networking
resource "aws_vpc" "instana" {
  cidr_block                           = local.vpc_base_cidr
  enable_network_address_usage_metrics = true
  
  enable_dns_support = true
  enable_dns_hostnames = true

  tags = {
    Name = "sos-${terraform.workspace}-vpc"
    Role = "vpc"
  }
}

resource "aws_internet_gateway" "instana" {
  vpc_id = aws_vpc.instana.id

  tags = {
    Name = "sos-${terraform.workspace}-gw"
    Role = "internet-gateway"
  }
}

resource "aws_vpc_ipv4_cidr_block_association" "public_cidr" {
  for_each = local.public_cidr_blocks

  vpc_id     = aws_vpc.instana.id
  cidr_block = each.value
}

resource "aws_vpc_ipv4_cidr_block_association" "private_cidr" {
  for_each = local.private_cidr_blocks

  vpc_id     = aws_vpc.instana.id
  cidr_block = each.value
}

resource "aws_subnet" "public_subnet" {
  for_each = local.public_cidr_blocks

  vpc_id            = aws_vpc_ipv4_cidr_block_association.public_cidr[each.key].vpc_id
  cidr_block        = each.value
  availability_zone = each.key

  map_public_ip_on_launch = true

  tags = {
    Name       = "sos-${terraform.workspace}-public-${each.key}"
    Role       = "subnet"
    Visibility = "public"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.instana.id

  tags = {
    Name       = "sos-${terraform.workspace}-rt-public"
    Role       = "route-table"
    Visibility = "public"
  }
}

resource "aws_route" "public_subnet_internet_gateway" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.instana.id
}

resource "aws_route_table_association" "public_subnet_public_table" {
  for_each = local.public_cidr_blocks

  subnet_id      = aws_subnet.public_subnet[each.key].id
  route_table_id = aws_route_table.public.id
}

resource "aws_subnet" "private_subnet" {
  for_each = local.private_cidr_blocks

  vpc_id            = aws_vpc_ipv4_cidr_block_association.private_cidr[each.key].vpc_id
  cidr_block        = each.value
  availability_zone = each.key

  tags = {
    Name       = "sos-${terraform.workspace}-private-${each.key}"
    Role       = "subnet"
    Visibility = "private"
  }
}

resource "aws_eip" "region_ip" {
  for_each = local.private_cidr_blocks
  
  vpc              = true
  
  tags = {
    Name       = "sos-${terraform.workspace}-ip-${each.key}"
    Role       = "eip"
    Visibility = "public"
  }
  
  depends_on = [aws_internet_gateway.instana]  
}

resource "aws_nat_gateway" "instana" {
  for_each = local.private_cidr_blocks

  subnet_id = aws_subnet.public_subnet[each.key].id
  allocation_id = aws_eip.region_ip[each.key].id

  tags = {
    Name       = "sos-${terraform.workspace}-nat-${each.key}"
    Role       = "nat-gateway"
    Visibility = "public"
  }

  depends_on = [aws_internet_gateway.instana]
}

resource "aws_route_table" "private" {
  for_each = local.private_cidr_blocks
  vpc_id   = aws_vpc.instana.id

  tags = {
    Name       = "sos-${terraform.workspace}-rt-private-${each.key}"
    Role       = "route-table"
    Visibility = "private"
  }
}

resource "aws_route" "private_subnet_nat_gateway" {
  for_each = local.private_cidr_blocks

  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id             = aws_nat_gateway.instana[each.key].id
}

resource "aws_route_table_association" "private_subnet_private_table" {
  for_each = local.private_cidr_blocks

  subnet_id      = aws_subnet.private_subnet[each.key].id
  route_table_id = aws_route_table.private[each.key].id
}

# Site To Site VPN
resource "aws_customer_gateway" "sos" {
  bgp_asn    = 65000
  ip_address = var.sos_vpn_endpoint
  type       = "ipsec.1"

  tags = {
    Name = "sos-${terraform.workspace}-cg"
    Role       = "vpn"
    Visibility = "public"
  }
}

resource "aws_vpn_gateway" "vpn_gateway" {
  vpc_id = aws_vpc.instana.id
  
  tags = {
    Name = "sos-${terraform.workspace}-gw"
    Role       = "vpn"
    Visibility = "public"
  }
}

data "aws_secretsmanager_secret" "tunnel1_psk_secret" {
  name = "sos-${terraform.workspace}-tunnel1-secret"
}

data "aws_secretsmanager_secret_version" "tunnel1_psk_secret_version" {
  secret_id = data.aws_secretsmanager_secret.tunnel1_psk_secret.id
}

resource "aws_vpn_connection" "sos" {
  vpn_gateway_id      = aws_vpn_gateway.vpn_gateway.id
  customer_gateway_id = aws_customer_gateway.sos.id
  
  type                = "ipsec.1"
  static_routes_only  = true
  
  local_ipv4_network_cidr = var.sos_cidr
  
  tunnel1_preshared_key = data.aws_secretsmanager_secret_version.example.secret_string
  tunnel1_ike_versions = ["ikev2"]
  
  tunnel1_phase1_dh_group_numbers = [15]
  tunnel1_phase1_integrity_algorithms = ["SHA2-256"]
  tunnel1_phase1_encryption_algorithms = ["AES256"]
  
  tunnel1_phase2_dh_group_numbers = [15]
  tunnel1_phase2_integrity_algorithms = ["SHA2-256"]
  tunnel1_phase2_encryption_algorithms = ["AES256"]
  
  tags = {
    Name = "sos-${terraform.workspace}-conn"
    Role       = "vpn"
    Visibility = "public"
  }
}

resource "aws_vpn_connection_route" "sos_all" {
  destination_cidr_block = "10.0.0.0/8"
  vpn_connection_id      = aws_vpn_connection.sos.id
}

resource "aws_vpn_gateway_route_propagation" "sos_vpn_link" {
  for_each = local.private_cidr_blocks
  
  vpn_gateway_id = aws_vpn_gateway.vpn_gateway.id
  route_table_id = aws_route_table.private[each.key].id
}