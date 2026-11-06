variable "region" {
  description = "Region to place the jumpbox in. Use the region where your model is being served."
  type        = string
}

variable "vpc_name" {
  description = "Name of the VPC to launch the jumpbox into (the SkySpot VPC)."
  type        = string
  default     = "skyspot-vpc"
}

variable "instance_type" {
  description = "Jumpbox size. It runs the sky CLI AND keeps a SkyPilot API server resident while `sky jobs launch` waits for provisioning, which needs ~4 GB; t3.micro (1 GB) can't install sky and t3.small (2 GB) swaps and drops its SSM agent under a managed-job launch. t3.medium is the floor."
  type        = string
  default     = "t3.medium"
}

variable "name" {
  description = "Name tag for the jumpbox resources."
  type        = string
  default     = "skyspot-jumpbox"
}

variable "tags" {
  type = map(string)
  default = {
    Project   = "SkySpot"
    ManagedBy = "Terraform"
  }
}
