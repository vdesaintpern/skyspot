# How a SkySpot job runs (regions, price cap, failover)

This is the mental model behind every recipe. Read it once and the YAML files
make sense.

## Why more than one region?
Each `(region, instance-type)` pair is a separate **spot capacity pool** with its
own price and its own chance of being available or preempted. Listing several
regions means:
- **More chances to get GPUs at all** - if eu-north-1 is out of L4 spot, ap-south-1
  might have it.
- **A lower price** - SkyPilot shops across pools and takes the cheapest under your cap.
- **Resilience** - if your spot GPU is preempted, the job moves to another pool
  instead of dying.

You are not running in all regions at once - you run in **one** pool at a time.
The extra regions are the bench you draw from.

## What a recipe declares
```yaml
resources:
  accelerators: {RTXPRO6000:1, L4:1, A10G:1}   # any of these GPUs
  use_spot: true                                # spot, not on-demand
  max_hourly_cost: 2.0                          # per-node USD/hr ceiling
  any_of:                                       # the regions to consider
    - {cloud: aws, region: eu-north-1}
    - {cloud: aws, region: ap-south-1}
    - {cloud: aws, region: us-east-1}
  job_recovery:
    strategy: EAGER_NEXT_REGION                 # how to recover from preemption
```

## Order of execution
1. **Build candidates.** SkyPilot expands `accelerators x any_of` into every
   `(GPU, region)` pair that actually exists (e.g. it drops a GPU family from a
   region that does not offer it).
2. **Apply the price cap.** Any candidate whose current spot price is above
   `max_hourly_cost` is removed.
3. **Sort by price, cheapest first.**
4. **Launch the cheapest.** Provision the spot GPU in that pool. If provisioning
   fails (no capacity right now), fall to the **next** candidate, and so on.

### Worked example (illustrative optimizer output for recipe 01)
With `max_hourly_cost: 2.0` across eu-north-1 / ap-south-1 / us-east-1, the
optimizer produces something like:
```
 INFRA               INSTANCE            GPUS           COST($/hr)   CHOSEN
 AWS (eu-north-1b)   g6.2xlarge[Spot]    L4:1           0.18          ✔
 AWS (eu-north-1c)   g5.2xlarge[Spot]    A10G:1         0.24
 AWS (us-east-1a)    g6.2xlarge[Spot]    L4:1           0.28
```
Candidates over the $2 cap are dropped, and a region that does not offer a given
GPU contributes no candidate for it. Result: cheapest eligible pool wins -> L4 in
eu-north-1 at **$0.18/hr**.

## Fallback / recovery
- **Provisioning failure** (capacity stockout at launch): SkyPilot moves to the
  next cheapest candidate automatically.
- **Spot preemption mid-run** (training, managed jobs): `job_recovery:
  EAGER_NEXT_REGION` re-provisions immediately, **eagerly trying the next region**
  rather than waiting for the same pool to recover. Training resumes from the last
  checkpoint on S3 (recipes 01/02 periodically sync `/outputs` to the region-local
  weights bucket for exactly this reason).
- **Serving** (recipes 03/04): SkyServe keeps the endpoint alive;
  `dynamic_ondemand_fallback: true` launches an on-demand replica only when spot
  cannot be provisioned, so the endpoint does not go dark during a stockout.

## Connecting to nodes: why you run sky on the jumpbox

SkyPilot connects to the controller and workers over **SSH**. There are two ways
to reach instances that sit in private subnets with no public IP:

- **SSM** (`use_ssm: true`) - tunnel SSH through AWS Session Manager. Required when
  the client is *outside* the VPC (your laptop). **But** from an *in-VPC* client
  (the controller) the SSM data path reliably drops the SSH key exchange
  (`kex_exchange_identification: Connection closed`, 600 s timeout, retry loop).
  This was reproduced and isolated: laptop->worker over SSM works; controller->worker
  over SSM fails - same worker, same VPC, only the client differs.
- **Direct private-IP SSH** (`use_ssm: false`, `use_internal_ips: true`) - works
  whenever the client shares the network with the target. From an in-VPC host this
  just works.

So the design is: **run the `sky` CLI on the in-VPC jumpbox** (you reach the
jumpbox over SSM for an interactive shell), and set **`use_ssm: false`** so every
SkyPilot hop (jumpbox->controller, controller->worker) is direct private-IP SSH.

> **Config trap:** `use_internal_ips: true` *alone* makes SkyPilot silently default
> to SSM ("Defaulting to using SSM"). You must set `use_ssm: false` **explicitly**
> to get direct SSH. That one line is the difference between working and the
> 600 s-timeout retry loop. The jumpbox bootstrap writes it for you.

## The controller (managed jobs and serving)

`sky jobs launch` and `sky serve up` do not talk to the GPU directly. SkyPilot
first creates a small, long-lived **controller** instance that orchestrates the
work: it provisions and monitors the GPU worker(s), runs the preemption/failover
loop for managed jobs, and manages replicas for SkyServe. The controller is
**shared across all your jobs** and **autostops** after a period idle, relaunching
on the next submission. It is reached only through the SkyPilot CLI/API, not SSH.

Key behaviors that surprise people:

- **It is a real instance and it persists.** The first `sky jobs launch` creates
  it (SkyPilot picks a small default, e.g. `m6i.xlarge`); later jobs reuse it.
- **It inherits the `aws:` config** (direct private-IP SSH, `use_ssm: false`), so
  it lands in `skyspot-vpc` and talks to workers the same way the jumpbox talks to
  it. Therefore the controller's region must have a `skyspot-vpc`, or its launch
  fails the VPC lookup. The jumpbox bootstrap (`infra/jumpbox/bootstrap.sh.tftpl`)
  pins this into `/root/.sky/config.yaml` from the Terraform `region` variable;
  `config/sky-config.example.yaml` is a reference copy of the same shape:
  ```yaml
  jobs:
    controller:
      resources: {cloud: aws, region: eu-north-1}   # a region with skyspot-vpc
  serve:
    controller:
      resources: {cloud: aws, region: eu-north-1}
  ```
- **Config changes do not move an existing controller.** It is sticky to wherever
  it was first created. If you change the controller config (or created one before
  setting up `skyspot-vpc`), tear the old one down so it is recreated under the new
  settings: find its name with `sky status`, then `sky down sky-jobs-controller-<hash>`
  (you will be prompted to type `delete`).
- **It costs a little while running** but autostops when idle; remove it entirely
  with the command above when you are done.

## How to add a region (beyond the default trio)

The standard setup already wires three regions (`eu-north-1`, `ap-south-1`,
`us-east-1`) end to end - VPCs, peering, and training-data replication. To add a
**fourth** region (say `eu-west-2`):

1. **Create a VPC there** with a distinct, non-overlapping CIDR:
   ```bash
   cd infra/vpc && terraform workspace new eu-west-2
   terraform apply -var="region=eu-west-2" -var="vpc_cidr=10.14.0.0/16"
   ```
2. **Extend the peering stack.** `infra/peering` is parameterized for one primary +
   two secondaries. For a third secondary, add a `sec3` provider (in `versions.tf`),
   a `aws_vpc_peering_connection`/`_accepter` pair, and the two `aws_route` blocks
   for it in `main.tf` - copy the `sec2` block and rename. Then `terraform apply`.
3. **Extend the replication stack.** In `infra/data-replication`, add a `sec3`
   provider, a `module "sec3"` instance (to create that region's buckets), and a
   third `rule {}` in `aws_s3_bucket_replication_configuration.training`. Apply, then
   re-upload the data (or run S3 Batch Replication) so the new region gets a copy -
   CRR only replicates objects created after the rule exists.
4. **Add it to the recipe's `any_of:`** and check **quota / opt-in.** Big GPUs often
   need a spot-quota increase (an 8-GPU G node needs 192 G-and-VT spot vCPUs). Some
   regions are opt-in and must be enabled on the account first; some sandbox accounts
   cannot enable opt-in regions, so avoid them there (e.g. ap-south-2).
5. **Preflight**, then launch:
   ```bash
   ./scripts/preflight.sh skyspot-vpc "eu-north-1 ap-south-1 us-east-1 eu-west-2"
   ```

Serving recipes (03/04) keep each replica in a single region, so they need the VPC
and (if they read S3) replicated data, but **not** peering.

## GPU availability by region (reference catalog)

Which GPU families are offered where, verified against the EC2
`DescribeInstanceTypeOfferings` API (Nov 2026). `yes` = offered. Use this to choose
regions for a recipe's `any_of:`.

```
family      gpu          eu-north-1  ap-south-1  us-east-1  eu-west-2
g6          L4            yes         yes         yes        yes
g5          A10G          yes         yes         yes        yes
p5          H100          yes         yes         yes        yes
p5en        H200          yes         yes         yes        no
p6-b200     B200          yes         yes         yes        no
p6-b300     B300          no          no          yes        yes
```

> `g7e` (RTX PRO 6000) is listed in the recipes' `accelerators` for the future, but
> no `g7e` instance size is offered in these regions yet, so SkyPilot simply skips
> it today. It stays in the recipe so it is picked up automatically once available.

- Recipes 01-03 (G instances): all three default regions offer g6/g5 - full coverage.
- Recipe 04 (large serve, **2x 8x H200** / `p5en`): offered in all three default
  regions. B200 is a valid 2-node alternative (also in all three). B300 (us-east-1,
  eu-west-2) is a single-node topology - a separate recipe, not a swap.

Other regions that carry the full GPU line-up if you want to widen the pool (each
needs its own VPC): us-east-2, us-west-2, ap-northeast-1, ap-northeast-2.

## Tuning the price cap
`max_hourly_cost` is the per-node ceiling.
- Too **low** -> every candidate is filtered out and the job sits PENDING ("no
  resource satisfying ... max_cost").
- Too **high** -> you might land on a pricier pool than you intended.
Set it just above the spot price of the most expensive GPU you are willing to use.
See `cost-and-spot.md` for the per-recipe defaults.
