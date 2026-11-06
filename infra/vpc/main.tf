# SkySpot standard VPC (one per region).
#
# Layout:
#   - Spans ALL Availability Zones in the region.
#   - PRIVATE subnets host every GPU workload (no public IP).
#   - Small PUBLIC subnets exist only to hold the single NAT gateway (a NAT gw
#     cannot live in a private subnet). No workload is placed there.
#   - 1 NAT gateway gives private nodes egress for pip / Hugging Face / Docker.
#   - S3 gateway endpoint: free, fast path to S3 (training data + weights).
#   - SSM interface endpoints: let you reach the JUMPBOX over Session Manager with
#     no public IP and no inbound SSH. (SkyPilot itself uses direct private-IP SSH
#     from the in-VPC jumpbox - use_ssm: false - not SSM.)

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = data.aws_availability_zones.available.names

  # Carve /20 private subnets and /24 public subnets out of the VPC CIDR.
  private_subnets = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 8, 240 + i)]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13"

  name = var.vpc_name
  cidr = var.vpc_cidr
  azs  = local.azs

  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets

  # Single NAT gateway for the whole VPC (cost-efficient; meets the 1-NAT ask).
  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false

  enable_dns_hostnames = true
  enable_dns_support   = true

  # Tag private subnets so SkyPilot/humans can tell them apart.
  private_subnet_tags = { Tier = "private-workload" }
  public_subnet_tags  = { Tier = "public-nat-only" }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# VPC endpoints
# ---------------------------------------------------------------------------

# S3 gateway endpoint - free, keeps training-data/weights traffic off the NAT.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids
  tags              = merge(var.tags, { Name = "${var.vpc_name}-s3" })
}

# Security group for the SSM interface endpoints: allow HTTPS from inside the VPC.
resource "aws_security_group" "vpce" {
  name_prefix = "${var.vpc_name}-vpce-"
  description = "HTTPS from VPC to SSM interface endpoints"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "HTTPS from within the VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.vpc_name}-vpce" })
}

# Interface endpoints required for Session Manager over private subnets.
resource "aws_vpc_endpoint" "ssm" {
  for_each = toset(["ssm", "ssmmessages", "ec2messages"])

  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true
  tags                = merge(var.tags, { Name = "${var.vpc_name}-${each.key}" })
}
