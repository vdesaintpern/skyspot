variable "region" {
  description = "Region to create the buckets in. Keep it close to where training runs; cross-region S3 reads work but add transfer cost/latency."
  type        = string
  default     = "eu-north-1"
}

variable "name_prefix" {
  description = "Prefix for the bucket names. Final names are <prefix>-training-<account-id>-<region> and <prefix>-weights-<account-id>-<region> (globally unique, and region-suffixed so the same deployment can span regions). Pass this value to the recipe as BUCKET_PREFIX."
  type        = string
  default     = "skyspot"
}

variable "force_destroy" {
  description = "Allow `terraform destroy` to delete non-empty buckets. true is convenient for an eval; set false to protect real data."
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
