# Per-region training + weights buckets, matching the naming and hardening of
# infra/data. Instantiated once per secondary region (with that region's provider)
# by the parent stack. The training bucket here is a CRR *destination*; the weights
# bucket is where a job that lands in this region writes its outputs locally.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40"
    }
  }
}

variable "name_prefix" { type = string }
variable "account_id" { type = string }
variable "region" { type = string }
variable "force_destroy" { type = bool }
variable "tags" { type = map(string) }

locals {
  training_bucket = "${var.name_prefix}-training-${var.account_id}-${var.region}"
  weights_bucket  = "${var.name_prefix}-weights-${var.account_id}-${var.region}"
}

resource "aws_s3_bucket" "training" {
  bucket        = local.training_bucket
  force_destroy = var.force_destroy
  tags          = merge(var.tags, { Name = local.training_bucket, Role = "training-data" })
}

# Versioning is required on a CRR destination.
resource "aws_s3_bucket_versioning" "training" {
  bucket = aws_s3_bucket.training.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket" "weights" {
  bucket        = local.weights_bucket
  force_destroy = var.force_destroy
  tags          = merge(var.tags, { Name = local.weights_bucket, Role = "model-weights" })
}

resource "aws_s3_bucket_versioning" "weights" {
  bucket = aws_s3_bucket.weights.id
  versioning_configuration {
    status = "Enabled"
  }
}

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

output "training_bucket_id" {
  value = aws_s3_bucket.training.id
}

output "training_bucket_arn" {
  value = aws_s3_bucket.training.arn
}

output "weights_bucket_id" {
  value = aws_s3_bucket.weights.id
}
