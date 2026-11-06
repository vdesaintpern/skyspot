variable "region" {
  description = "AWS region to create the VPC in. Run this stack once per region you want SkyPilot to use."
  type        = string
}

variable "vpc_name" {
  description = "Name tag for the VPC. MUST match vpc_name in ~/.sky/config.yaml. Keep it identical across regions."
  type        = string
  default     = "skyspot-vpc"
}

variable "vpc_cidr" {
  description = <<-EOT
    CIDR block for the VPC. MUST be distinct per region if you ever want to peer
    the VPCs or attach them to a Transit Gateway (overlapping ranges cannot be
    connected). Pass a distinct value per region, e.g. -var="vpc_cidr=10.11.0.0/16"
    (see the CIDR table in README.md). The default is only safe for a single isolated VPC.
  EOT
  type        = string
  default     = "10.10.0.0/16"
}

variable "tags" {
  description = "Extra tags applied to all resources."
  type        = map(string)
  default = {
    Project   = "SkySpot"
    ManagedBy = "Terraform"
  }
}
