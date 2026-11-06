output "training_bucket" {
  description = "Primary-region input dataset bucket (<prefix>-training-<account>-<region>)."
  value       = aws_s3_bucket.training.id
}

output "weights_bucket" {
  description = "Primary-region output/checkpoints bucket (<prefix>-weights-<account>-<region>)."
  value       = aws_s3_bucket.weights.id
}

output "region" {
  value = var.region
}

output "account_id" {
  value = local.account_id
}

output "bucket_prefix" {
  description = "Pass this to the recipe as BUCKET_PREFIX. Recipes append -<account>-<region> at runtime."
  value       = var.name_prefix
}

# Ready-to-paste into recipes/01 and 02 finetune.sky.yaml. The recipes resolve the
# region (and bucket name) at runtime, so you only set the prefix - no region here.
output "recipe_envs" {
  description = "Paste under envs: in the training recipe (01/02)."
  value       = <<-EOT
    envs:
      BUCKET_PREFIX: ${var.name_prefix}
      DATA_FILE: dolly/train.jsonl
  EOT
}

output "init_data_hint" {
  description = "Populate the PRIMARY training bucket with the sample dataset (replicates to secondaries via infra/data-replication)."
  value       = "./init-data.sh ${aws_s3_bucket.training.id} 1000 ${var.region}"
}
