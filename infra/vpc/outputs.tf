output "vpc_name" {
  description = "VPC Name tag - paste into ~/.sky/config.yaml as aws.vpc_name."
  value       = var.vpc_name
}

output "vpc_id" {
  description = "VPC id of the created VPC."
  value       = module.vpc.vpc_id
}

output "region" {
  value = var.region
}

output "private_subnets" {
  description = "Private subnet ids where workloads run."
  value       = module.vpc.private_subnets
}

output "azs" {
  description = "Availability Zones the VPC spans."
  value       = local.azs
}

output "sky_config_snippet" {
  description = "Reference aws: block for the jumpbox's ~/.sky/config.yaml (the jumpbox bootstrap writes this automatically)."
  value       = <<-EOT
    aws:
      vpc_name: ${var.vpc_name}
      use_internal_ips: true
      use_ssm: false   # direct private-IP SSH; sky runs on the in-VPC jumpbox
  EOT
}
