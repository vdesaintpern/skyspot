# SkySpot inter-region VPC peering (hub-and-spoke).
#
# Why: the SkyPilot jobs controller lives in the PRIMARY VPC and reaches workers
# over DIRECT private-IP SSH (use_ssm: false). If a managed job fails over to a
# worker in another region, that worker is only reachable if the two VPCs are
# peered, with route-table entries both ways. This stack creates:
#   - a VPC peering connection primary <-> each secondary (accepted cross-region), and
#   - routes in each VPC's PRIVATE route tables to the peer's CIDR.
#
# Secondaries are NOT peered to each other: a single managed job runs in one region
# at a time, and the controller (primary) only ever needs a path to wherever the
# current worker landed. Hub-and-spoke from the primary is sufficient.
#
# Security groups: SkyPilot creates its own per-cluster SGs (sky-sg-*) that this
# stack does not manage. SkyPilot's default allows SSH, so the routes here are
# normally all that is needed. If you restrict SkyPilot's SG, also allow TCP 22
# from the primary VPC CIDR on the worker side. VPC CIDRs MUST NOT overlap (the
# infra/vpc CIDR table already assigns distinct ranges).

# ------------------------------------------------------------------ discover VPCs
data "aws_vpc" "primary" {
  filter {
    name   = "tag:Name"
    values = [var.vpc_name]
  }
}

data "aws_vpc" "sec1" {
  provider = aws.sec1
  filter {
    name   = "tag:Name"
    values = [var.vpc_name]
  }
}

data "aws_vpc" "sec2" {
  provider = aws.sec2
  filter {
    name   = "tag:Name"
    values = [var.vpc_name]
  }
}

# Private route tables (tagged "<vpc_name>-private*" by the VPC module).
data "aws_route_tables" "primary" {
  vpc_id = data.aws_vpc.primary.id
  filter {
    name   = "tag:Name"
    values = ["${var.vpc_name}-private*"]
  }
}

data "aws_route_tables" "sec1" {
  provider = aws.sec1
  vpc_id   = data.aws_vpc.sec1.id
  filter {
    name   = "tag:Name"
    values = ["${var.vpc_name}-private*"]
  }
}

data "aws_route_tables" "sec2" {
  provider = aws.sec2
  vpc_id   = data.aws_vpc.sec2.id
  filter {
    name   = "tag:Name"
    values = ["${var.vpc_name}-private*"]
  }
}

# ------------------------------------------------------------------ peering: sec1
resource "aws_vpc_peering_connection" "sec1" {
  vpc_id      = data.aws_vpc.primary.id
  peer_vpc_id = data.aws_vpc.sec1.id
  peer_region = var.secondary_region_1
  auto_accept = false
  tags        = merge(var.tags, { Name = "skyspot-peer-${var.primary_region}-${var.secondary_region_1}" })
}

resource "aws_vpc_peering_connection_accepter" "sec1" {
  provider                  = aws.sec1
  vpc_peering_connection_id = aws_vpc_peering_connection.sec1.id
  auto_accept               = true
  tags                      = merge(var.tags, { Name = "skyspot-peer-${var.primary_region}-${var.secondary_region_1}-accepter" })
}

resource "aws_route" "primary_to_sec1" {
  for_each                  = toset(data.aws_route_tables.primary.ids)
  route_table_id            = each.value
  destination_cidr_block    = data.aws_vpc.sec1.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.sec1.id
  depends_on                = [aws_vpc_peering_connection_accepter.sec1]
}

resource "aws_route" "sec1_to_primary" {
  provider                  = aws.sec1
  for_each                  = toset(data.aws_route_tables.sec1.ids)
  route_table_id            = each.value
  destination_cidr_block    = data.aws_vpc.primary.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.sec1.id
  depends_on                = [aws_vpc_peering_connection_accepter.sec1]
}

# ------------------------------------------------------------------ peering: sec2
resource "aws_vpc_peering_connection" "sec2" {
  vpc_id      = data.aws_vpc.primary.id
  peer_vpc_id = data.aws_vpc.sec2.id
  peer_region = var.secondary_region_2
  auto_accept = false
  tags        = merge(var.tags, { Name = "skyspot-peer-${var.primary_region}-${var.secondary_region_2}" })
}

resource "aws_vpc_peering_connection_accepter" "sec2" {
  provider                  = aws.sec2
  vpc_peering_connection_id = aws_vpc_peering_connection.sec2.id
  auto_accept               = true
  tags                      = merge(var.tags, { Name = "skyspot-peer-${var.primary_region}-${var.secondary_region_2}-accepter" })
}

resource "aws_route" "primary_to_sec2" {
  for_each                  = toset(data.aws_route_tables.primary.ids)
  route_table_id            = each.value
  destination_cidr_block    = data.aws_vpc.sec2.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.sec2.id
  depends_on                = [aws_vpc_peering_connection_accepter.sec2]
}

resource "aws_route" "sec2_to_primary" {
  provider                  = aws.sec2
  for_each                  = toset(data.aws_route_tables.sec2.ids)
  route_table_id            = each.value
  destination_cidr_block    = data.aws_vpc.primary.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.sec2.id
  depends_on                = [aws_vpc_peering_connection_accepter.sec2]
}
