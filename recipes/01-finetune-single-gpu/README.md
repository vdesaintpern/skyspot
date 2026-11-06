# Recipe 01 - single-GPU fine-tune on spot

LoRA fine-tune a small model on **one** GPU, on spot, cheapest-first across
**g7e / g6 / g5** in three regions, with price cap and auto-failover.

## What you get
- **Input**: your training data, read into `/data` from the region-local training
  bucket (`skyspot-training-<account>-<region>`).
- **Output**: LoRA adapter synced from `/outputs` to the region-local weights bucket
  - durable across spot preemptions (a background loop syncs every ~2 min). Final
  location: `s3://skyspot-weights-<account>-<region>/runs/<run-id>/`.

The recipe resolves the region (and therefore the bucket names) at runtime, so it
reads and writes **locally** in whichever region the spot GPU lands - no bucket
name is hardcoded.

> Run sky from the **jumpbox** (`../../infra/jumpbox`), not your laptop. It has
> SkyPilot pre-installed with the direct-SSH config. SSM into it, make sure this
> repo is present there, and run the commands below from the repo root.

## Before you launch
1. The VPC + jumpbox are up (`../../infra/vpc`, `../../infra/jumpbox`), you are in
   an SSM shell on the jumpbox, and `sky check aws` is green.
2. Buckets + sample data: run `../../infra/data` (primary region) and, for
   multi-region, `../../infra/data-replication` so the data exists in every region.
   For a quick smoke test without buckets, set `envs.DATA_FILE: ""` to use a public
   dataset (no S3 read needed).
3. In `finetune.sky.yaml`, usually nothing to edit - the recipe resolves its buckets
   at runtime. Just confirm:
   - `envs.BUCKET_PREFIX` matches the `name_prefix` you deployed (default `skyspot`).
   - `envs.DATA_FILE` -> path under the training bucket to your JSONL
     (`{"instruction","input","output"}` per line); the sample is `dolly/train.jsonl`.
   - `any_of:` lists only regions where you deployed a VPC (+ data/peering).
   - Optionally `envs.MODEL_NAME` (default `Qwen/Qwen3.5-4B`).

## Run
```bash
sky jobs launch -n ft-single recipes/01-finetune-single-gpu/finetune.sky.yaml -y
sky jobs queue            # watch state: STARTING -> RUNNING -> SUCCEEDED
sky jobs logs ft-single   # tail logs; look for decreasing loss
```
`sky jobs launch` runs it as a **managed job**: SkyPilot provisions the spot GPU,
runs training, and on preemption re-provisions (another region if needed) and
resumes. The cluster auto-terminates when the job finishes.

## Where the weights are
At the end the log prints the run id. Your adapter + tokenizer are at:
```
s3://<your weights bucket>/runs/<run-id>/
```
Load them later with `PeftModel.from_pretrained(base_model, "s3://.../runs/<run-id>")`
(after syncing locally) or point recipe 03 at them.

## Tuning
- `max_hourly_cost` in the YAML is the per-node spot cap. Raise it if jobs stay
  PENDING (no capacity under the cap); lower it to be stricter on cost.
- **Model size vs GPU memory.** `train.py` uses gradient checkpointing + a small
  batch so a ~4B LoRA fine-tune fits a **24GB** card (g6 L4 / g5 A10G). Even so, a
  4B model on 24GB is tight; if you hit `CUDA out of memory`, lower
  `per_device_train_batch_size`/`max_length`, pick a smaller model, or use a
  roomier GPU: **g6e** (L40S, 48GB) or **g7e** (RTX PRO 6000, 96GB), which also let
  you raise the batch size. Validated end to end on a g5 (A10G) spot instance with
  a 0.5B model; a 4B needs the memory-saving settings above or a bigger card.
