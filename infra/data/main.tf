# SkySpot example data + weights buckets (PRIMARY region).
#
# Two S3 buckets for the training recipes (01, 02), named with a region suffix so
# the same deployment can exist in several regions side by side:
#   - training : your input dataset (recipes read it at /data)       <prefix>-training-<account>-<region>
#   - weights  : fine-tune outputs/checkpoints (recipes write /outputs) <prefix>-weights-<account>-<region>
#
# This stack creates ONLY the primary region's buckets. For multi-region, run
# infra/data-replication afterwards: it creates the matching buckets in the
# secondary regions and replicates this training bucket into them (CRR), so a job
# that fails over to another region still reads its data locally. The recipes
# compose the bucket name at runtime from BUCKET_PREFIX + account + the region they
# land in, so you never hardcode a region into a recipe.
#
# After `terraform apply`, run `init-data.sh` to populate the training bucket with
# a small public dataset so you have a full, runnable example. Run it AFTER
# infra/data-replication is applied if you want the sample data to replicate.

data "aws_caller_identity" "current" {}

locals {
  account_id      = data.aws_caller_identity.current.account_id
  training_bucket = "${var.name_prefix}-training-${local.account_id}-${var.region}"
  weights_bucket  = "${var.name_prefix}-weights-${local.account_id}-${var.region}"
}

# ---------------------------------------------------------------- training bucket
resource "aws_s3_bucket" "training" {
  bucket        = local.training_bucket
  force_destroy = var.force_destroy
  tags          = merge(var.tags, { Name = local.training_bucket, Role = "training-data" })
}

# Versioning is REQUIRED on a cross-region replication source, so the training
# bucket can be the CRR source for infra/data-replication.
resource "aws_s3_bucket_versioning" "training" {
  bucket = aws_s3_bucket.training.id
  versioning_configuration {
    status = "Enabled"
  }
}

# ---------------------------------------------------------------- weights bucket
resource "aws_s3_bucket" "weights" {
  bucket        = local.weights_bucket
  force_destroy = var.force_destroy
  tags          = merge(var.tags, { Name = local.weights_bucket, Role = "model-weights" })
}

# Keep every checkpoint version (durability across spot preemptions / reruns).
resource "aws_s3_bucket_versioning" "weights" {
  bucket = aws_s3_bucket.weights.id
  versioning_configuration {
    status = "Enabled"
  }
}

# ---------------------------------------------------------------- hardening (both)
resource "aws_s3_bucket_public_access_block" "this" {
  for_each = {
    training = aws_s3_bucket.training.id
    weights  = aws_s3_bucket.weights.id
  }
  bucket                  = each.value
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = {
    training = aws_s3_bucket.training.id
    weights  = aws_s3_bucket.weights.id
  }
  bucket = each.value
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
