# Cost and spot behavior

## Price caps
Every recipe sets `resources.max_hourly_cost` - a **per-node** USD/hr ceiling.
SkyPilot only launches an instance whose (spot) price is under the cap, and picks
the cheapest eligible option across all candidate regions.

| Recipe | Cap (default) | Covers |
|--------|---------------|--------|
| 01 single-GPU | `2.0` | a single g7e/g6/g5 on spot |
| 02 8-GPU node | `20.0` | one 8-GPU g7e/g6/g5 box on spot |
| 03 serve small | `2.0` | a single-GPU vLLM replica on spot |
| 04 serve large | `40.0` | **per node** of an 8x H200 (`p5en.48xlarge`) box on spot; 2 nodes => up to ~2x |

Tune these:
- Job stuck **PENDING**? Capacity under your cap is unavailable - raise the cap,
  or widen `any_of` regions, or wait.
- Want a hard budget? Lower the cap; SkyPilot simply won't launch above it.

## Spot preemption
- **Training (recipes 01/02)** uses managed jobs with `EAGER_NEXT_REGION`. On
  preemption SkyPilot re-provisions (next region if needed) and resumes from the
  last checkpoint on S3. Keep `save_steps` reasonable so little work is lost.
- **Serving (recipes 03/04)** uses SkyServe. `dynamic_ondemand_fallback: true`
  runs replicas on spot and launches an on-demand replica only when spot cannot be
  provisioned, so the endpoint stays reachable. Set it `false` for pure-spot
  (cheaper, less available). For multi-replica services you can instead pin a floor
  with `base_ondemand_fallback_replicas: N` (N on-demand, the rest on spot).

## Capacity vs quota (especially P-class, recipe 04)
Two different gates, both can block you:
- **Quota**: for spot this is the aggregate **All P Spot Instance Requests**
  service-quota, measured in **vCPUs** (one 8-GPU P node = 192 vCPU). Recipe 04's
  2-node H200 replica needs **384 vCPU**; the default 768-vCPU P-spot quota in these
  regions covers it with no increase. The **on-demand** fallback uses a *separate*
  on-demand P quota that often starts at **0** - request an increase if you rely on
  `dynamic_ondemand_fallback`. Increases are a manual review (can take days).
- **Capacity**: even with quota, a region can be out of spot GPUs
  (`InsufficientInstanceCapacity`) - and two 8-GPU nodes in one AZ with EFA is a
  demanding spot ask. Multi-region candidates are the mitigation.
Available quota does **not** guarantee capacity - they are independent.

## Keeping the bill down
- The **NAT gateway** bills hourly + per-GB even when idle - `terraform destroy`
  the VPCs when you finish evaluating.
- Managed training jobs **auto-terminate** the cluster on completion; `sky status`
  should show nothing live afterwards.
- `sky serve down <name>` tears down a service; `sky down <cluster>` an interactive
  cluster. Check `sky status` / `sky serve status` before walking away.
