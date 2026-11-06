# SkySpot cross-region data replication.
#
# Problem this solves: a managed job can fail over to a secondary region, but S3
# buckets are regional. Without a local copy, a worker in ap-south-1 or us-east-1
# would have to read training data across regions (slow, and billed as inter-region
# transfer). This stack:
#   1. creates the training + weights buckets in each secondary region, and
#   2. sets up S3 Cross-Region Replication (CRR) from the PRIMARY training bucket
#      (created by infra/data) into each secondary training bucket.
#
# So after you upload data to the primary training bucket (init-data.sh), S3 copies
# it to the secondary regions automatically, and the recipe - which composes the
# bucket name from the region it lands in - always reads a LOCAL bucket.
#
# NOTE: CRR only replicates objects created AFTER replication is enabled. Apply this
# stack BEFORE running init-data.sh (or re-upload / S3 Batch Replication for
# existing objects). Weights are NOT replicated by default: each region writes to
# its own weights bucket; see README for aggregating them back to primary.

data "aws_caller_identity" "current" {}

locals {
  account_id       = data.aws_caller_identity.current.account_id
  src_training     = "${var.name_prefix}-training-${local.account_id}-${var.primary_region}"
  src_training_arn = "arn:aws:s3:::${local.src_training}"
}

# The primary training bucket already exists (infra/data). Reference it so we fail
# loudly if it is missing or not yet created.
data "aws_s3_bucket" "src_training" {
  bucket = local.src_training
}

# -------------------------------------------------------- secondary-region buckets
module "sec1" {
  source        = "./modules/region-buckets"
  providers     = { aws = aws.sec1 }
  name_prefix   = var.name_prefix
  account_id    = local.account_id
  region        = var.secondary_region_1
  force_destroy = var.force_destroy
  tags          = var.tags
}

module "sec2" {
  source        = "./modules/region-buckets"
  providers     = { aws = aws.sec2 }
  name_prefix   = var.name_prefix
  account_id    = local.account_id
  region        = var.secondary_region_2
  force_destroy = var.force_destroy
  tags          = var.tags
}

# -------------------------------------------------------- replication IAM role
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "replication" {
  name_prefix        = "skyspot-s3-crr-"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "replication" {
  # Read from the source bucket.
  statement {
    sid       = "SourceList"
    actions   = ["s3:GetReplicationConfiguration", "s3:ListBucket"]
    resources = [local.src_training_arn]
  }
  statement {
    sid = "SourceRead"
    actions = [
      "s3:GetObjectVersionForReplication",
      "s3:GetObjectVersionAcl",
      "s3:GetObjectVersionTagging",
    ]
    resources = ["${local.src_training_arn}/*"]
  }
  # Write to each destination bucket.
  statement {
    sid     = "DestWrite"
    actions = ["s3:ReplicateObject", "s3:ReplicateDelete", "s3:ReplicateTags"]
    resources = [
      "${module.sec1.training_bucket_arn}/*",
      "${module.sec2.training_bucket_arn}/*",
    ]
  }
}

resource "aws_iam_role_policy" "replication" {
  name_prefix = "skyspot-s3-crr-"
  role        = aws_iam_role.replication.id
  policy      = data.aws_iam_policy_document.replication.json
}

# -------------------------------------------------------- replication rules
# Attaches to the PRIMARY training bucket (owned by infra/data) and fans out to
# both secondary training buckets.
resource "aws_s3_bucket_replication_configuration" "training" {
  # Destination buckets must have versioning ENABLED before PutBucketReplication.
  # Depend on the whole module so its versioning resources finish first.
  depends_on = [module.sec1, module.sec2]

  role   = aws_iam_role.replication.arn
  bucket = data.aws_s3_bucket.src_training.id

  rule {
    id       = "to-${var.secondary_region_1}"
    status   = "Enabled"
    priority = 1
    filter {}
    delete_marker_replication {
      status = "Disabled"
    }
    destination {
      bucket        = module.sec1.training_bucket_arn
      storage_class = "STANDARD"
    }
  }

  rule {
    id       = "to-${var.secondary_region_2}"
    status   = "Enabled"
    priority = 2
    filter {}
    delete_marker_replication {
      status = "Disabled"
    }
    destination {
      bucket        = module.sec2.training_bucket_arn
      storage_class = "STANDARD"
    }
  }
}
