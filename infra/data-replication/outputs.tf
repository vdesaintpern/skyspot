output "source_training_bucket" {
  description = "CRR source (primary region) - upload data here with init-data.sh."
  value       = local.src_training
}

output "secondary_training_buckets" {
  description = "Replicated training buckets, one per secondary region."
  value = {
    (var.secondary_region_1) = module.sec1.training_bucket_id
    (var.secondary_region_2) = module.sec2.training_bucket_id
  }
}

output "secondary_weights_buckets" {
  description = "Per-region weights buckets where jobs landing in a secondary region write outputs."
  value = {
    (var.secondary_region_1) = module.sec1.weights_bucket_id
    (var.secondary_region_2) = module.sec2.weights_bucket_id
  }
}
