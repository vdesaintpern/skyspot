# infra/data - training data + weights buckets (the full example)

Creates the two S3 buckets the training recipes use, and populates the input one
with a small public dataset so you have a complete, runnable example. No dataset
is committed to this repo - `init-data.sh` downloads it on demand.

- **training bucket** `<prefix>-training-<account-id>-<region>` - your input data,
  read into `/data` by the recipe. Versioning on (required to be a replication source).
- **weights bucket** `<prefix>-weights-<account-id>-<region>` - fine-tune outputs and
  checkpoints, synced from `/outputs`. Versioning on, so reruns and spot-preemption
  checkpoints don't clobber each other.

Bucket names are **region-suffixed** so the same deployment can exist in several
regions. This stack creates the **primary** region's buckets; for multi-region, run
`infra/data-replication` next to create the secondary buckets and replicate the
training data into them.

## 1. Create the buckets
```bash
cd infra/data
terraform init
terraform apply -var="region=eu-north-1"
```

## 2. Load the sample dataset
```bash
./init-data.sh "$(terraform output -raw training_bucket)" 1000 eu-north-1
```
This downloads **databricks-dolly-15k** (CC BY-SA 3.0, commercial use OK), converts
the first 1000 rows to the `{instruction, input, output}` JSONL the recipes expect,
and uploads it to `s3://<training-bucket>/dolly/train.jsonl`. Bump `1000` for more
rows, or point the recipe at your own data instead.

## 3. Wire it into a recipe
Nothing to paste: recipes 01/02 resolve the bucket name at runtime from the region
they land in. Just make sure the recipe's `envs.BUCKET_PREFIX` matches the
`name_prefix` you deployed (default `skyspot`), which is also what
`terraform output recipe_envs` prints:
```yaml
envs:
  BUCKET_PREFIX: skyspot
  DATA_FILE: dolly/train.jsonl
```
Then launch the recipe as usual. Trained weights land in
`s3://<prefix>-weights-<account>-<region>/runs/<run-id>/` for whichever region the
job ran in.

## Notes
- This stack creates the **primary** region's buckets only. For failover to read
  data locally in other regions, run `infra/data-replication` (CRR). Without it, a
  job in a secondary region finds no training bucket for that region.
- `force_destroy = true` (default) lets `terraform destroy` remove the buckets even
  when non-empty - convenient for an eval. Set it `false` to protect real data; then
  empty the buckets yourself before destroying.

## Teardown
```bash
terraform destroy -var="region=eu-north-1"
```
