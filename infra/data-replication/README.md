# infra/data-replication - cross-region training data (multi-region only)

Makes the training data available **locally in every region** a job might run in,
and gives each secondary region a weights bucket to write to. Needed only for the
multi-region setup; a single-region deployment uses just `infra/data`.

What it creates:
- In each **secondary** region: a training bucket and a weights bucket, named like
  the primary ones (`<prefix>-training|weights-<account>-<region>`), versioned and
  hardened.
- **S3 Cross-Region Replication (CRR)** from the primary training bucket (created by
  `infra/data`) into each secondary training bucket, with the IAM role it needs.

So a recipe that fails over to `ap-south-1` or `us-east-1` reads
`skyspot-training-<account>-<that-region>` - a local copy - instead of pulling
across regions.

## Prerequisites
- `infra/data` applied in the primary region (its training bucket is the CRR source
  and has versioning enabled).
- The same `name_prefix` here as there (default `skyspot`).

## Apply
```bash
cd infra/data-replication
terraform init
terraform apply \
  -var="primary_region=eu-north-1" \
  -var="secondary_region_1=ap-south-1" \
  -var="secondary_region_2=us-east-1"
```

## Then load the data
CRR only copies objects created **after** the rules exist, so apply this stack
first, then upload:
```bash
cd ../data
./init-data.sh "$(terraform output -raw training_bucket)" 1000 eu-north-1
```
Objects land in the primary bucket and replicate to the secondaries within seconds
to minutes. To check:
```bash
aws s3 ls s3://skyspot-training-<account>-ap-south-1/dolly/ --region ap-south-1
```
(For data uploaded **before** replication was enabled, re-upload it or use S3 Batch
Replication - existing objects are not back-filled automatically.)

## Weights are regional (by design)
Each region writes outputs to its own weights bucket, so after a run look in the
region the job actually used (the job log prints it). To collect all outputs in one
place instead, add a reverse CRR rule (secondary weights -> primary) or periodically
`aws s3 sync` the secondary weights buckets to the primary. Not enabled by default to
keep inter-region transfer cost predictable.

## Teardown
```bash
terraform destroy \
  -var="primary_region=eu-north-1" \
  -var="secondary_region_1=ap-south-1" \
  -var="secondary_region_2=us-east-1"
```
`force_destroy = true` (default) lets this remove non-empty secondary buckets.
