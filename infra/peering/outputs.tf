output "peering_connection_ids" {
  description = "VPC peering connection ids (primary <-> each secondary)."
  value = {
    (var.secondary_region_1) = aws_vpc_peering_connection.sec1.id
    (var.secondary_region_2) = aws_vpc_peering_connection.sec2.id
  }
}

output "vpc_cidrs" {
  description = "Discovered VPC CIDRs (must be non-overlapping for peering to work)."
  value = {
    (var.primary_region)     = data.aws_vpc.primary.cidr_block
    (var.secondary_region_1) = data.aws_vpc.sec1.cidr_block
    (var.secondary_region_2) = data.aws_vpc.sec2.cidr_block
  }
}
