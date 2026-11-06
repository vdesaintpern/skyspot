variable "primary_region" {
  description = "Region hosting the jobs controller + jumpbox. Peering is hub-and-spoke from this VPC out to each secondary."
  type        = string
  default     = "eu-north-1"
}

variable "secondary_region_1" {
  description = "First secondary region a recipe can fail over into. Must already have a skyspot-vpc (infra/vpc)."
  type        = string
  default     = "ap-south-1"
}

variable "secondary_region_2" {
  description = "Second secondary region a recipe can fail over into."
  type        = string
  default     = "us-east-1"
}

variable "vpc_name" {
  description = "Name tag of the SkySpot VPC in every region (must be identical across regions)."
  type        = string
  default     = "skyspot-vpc"
}

variable "tags" {
  type = map(string)
  default = {
    Project   = "SkySpot"
    ManagedBy = "Terraform"
  }
}
