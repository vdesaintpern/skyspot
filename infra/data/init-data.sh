#!/usr/bin/env bash
# Populate the SkySpot training bucket with a small, ready-to-use fine-tuning
# dataset - so the recipes have a full working example without committing any
# data to this repo.
#
# Dataset: databricks-dolly-15k (CC BY-SA 3.0, commercial use OK). We take the
# first N rows and convert them to the {instruction, input, output} JSONL schema
# that the recipe train.py expects, then upload to the bucket.
#
# Usage:
#   ./init-data.sh <training-bucket> [rows] [region]
#   ./init-data.sh skyspot-training-123456789012 1000 eu-north-1
#
# Requires: curl, python3, and AWS CLI (with credentials for the bucket's account).
set -euo pipefail

BUCKET="${1:?training bucket name required (see: terraform output training_bucket)}"
ROWS="${2:-1000}"
REGION="${3:-eu-north-1}"
KEY="dolly/train.jsonl"
SRC_URL="https://huggingface.co/datasets/databricks/databricks-dolly-15k/resolve/main/databricks-dolly-15k.jsonl"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Downloading dolly-15k..."
curl -fsSL "$SRC_URL" -o "$tmp/dolly.jsonl"

echo "Converting first ${ROWS} rows to {instruction,input,output} JSONL..."
# Read program from stdin (-) and run isolated (-I) so nothing is imported from
# the download directory. The source file is passed as an argument, never executed.
python3 -I - "$tmp/dolly.jsonl" "$ROWS" > "$tmp/train.jsonl" <<'PY'
import json, sys
src, n = sys.argv[1], int(sys.argv[2])
with open(src, encoding="utf-8") as f:
    for i, line in enumerate(f):
        if i >= n:
            break
        r = json.loads(line)
        print(json.dumps({
            "instruction": r.get("instruction", ""),
            "input": r.get("context", ""),
            "output": r.get("response", ""),
        }))
PY

count="$(wc -l < "$tmp/train.jsonl" | tr -d ' ')"
echo "Uploading ${count} rows to s3://${BUCKET}/${KEY} ..."
aws s3 cp "$tmp/train.jsonl" "s3://${BUCKET}/${KEY}" --region "$REGION"

echo
echo "Done. In recipes/01 (or 02) finetune.sky.yaml set:"
echo "  envs.BUCKET_PREFIX: <the name_prefix you deployed, e.g. skyspot>"
echo "  envs.DATA_FILE:     ${KEY}"
echo
echo "The recipe appends -<account>-<region> to BUCKET_PREFIX at runtime, so this"
echo "upload only needs to go to the PRIMARY training bucket. If infra/data-replication"
echo "is already applied, CRR copies these objects to the secondary-region buckets."
