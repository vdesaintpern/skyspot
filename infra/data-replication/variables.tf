variable "primary_region" {
  description = "Region of the existing primary buckets created by infra/data. This is the CRR source and the controller/jumpbox region."
  type        = string
  default     = "eu-north-1"
}

variable "secondary_region_1" {
  description = "First secondary region to replicate into (must have a skyspot-vpc if a recipe lists it)."
  type        = string
  default     = "ap-south-1"
}

variable "secondary_region_2" {
  description = "Second secondary region to replicate into."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Must match the name_prefix used by infra/data. Bucket names are <prefix>-training|weights-<account>-<region>."
  type        = string
  default     = "skyspot"
}

variable "force_destroy" {
  description = "Allow terraform destroy to delete non-empty secondary buckets. true is convenient for an eval."
  type        = bool
  default     = true
}

variable "tags" {
  type = map(string)
  default = {
    Project   = "SkySpot"
    ManagedBy = "Terraform"
  }
}
