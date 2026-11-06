# Recipe 02 - multi-GPU single-node fine-tune on spot

Same as recipe 01, but on an **8-GPU single node** for faster / larger
fine-tunes. Data-parallel (DDP) across all GPUs via `torchrun`.

## Why single node
All 8 GPUs live on one instance (`g7e.48xlarge` / `g6.48xlarge` / `g5.48xlarge`),
connected by NVLink/PCIe on the same box. There is no inter-node network in play,
so GPU-to-GPU communication is already as co-located ("same spine") as it gets.
Multi-*node* training, where placement across the network matters, is recipe 04.

## Before you launch
Same as recipe 01: run sky from the **jumpbox** (`../../infra/jumpbox`) and create the
buckets + sample data with `../../infra/data` (plus `../../infra/data-replication` for
multi-region). The recipe resolves its region-local buckets at runtime, so you only
confirm `envs.BUCKET_PREFIX` (default `skyspot`), `DATA_FILE`, `MODEL_NAME`, and that
`any_of:` lists regions where you deployed VPCs.

## Run
```bash
sky jobs launch -n ft-multi recipes/02-finetune-multi-gpu-single-node/finetune.sky.yaml -y
sky jobs queue
sky jobs logs ft-multi
```

## Scaling notes
- `torchrun --nproc_per_node=$SKYPILOT_NUM_GPUS_PER_NODE` launches one process per
  GPU; Hugging Face Trainer wires up DDP automatically.
- **DDP** (default) replicates the model on each GPU - great for a 4B LoRA.
- For a base model too large to fit per GPU, switch to **FSDP** (sharded) by
  uncommenting the `fsdp=...` lines in `train.py`.
- `max_hourly_cost: 20.0` is the per-node cap for an 8-GPU box. Tune to budget;
  raise it if the job stays PENDING for lack of capacity under the cap.

## Where the weights are
`s3://<your weights bucket>/runs/<run-id>/` (run id printed at the end of the log).
