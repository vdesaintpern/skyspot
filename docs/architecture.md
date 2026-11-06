# SkySpot architecture

How the pieces fit together, and why.

## The core idea
SkyPilot takes one job spec and finds the cheapest place to run it across many
regions, on **spot** capacity, under a **price cap**, and re-launches elsewhere if
spot is preempted. You write the recipe once; SkyPilot does the shopping.

## Networking (the part that bites people)
```
            your laptop
                | SSM Session Manager (interactive shell + port-forward)
                v
   ┌────────────────────────────────────────────────────────────────┐
   │  SkySpot VPC (one per region, name: skyspot-vpc)                 │
   │                                                                  │
   │   public subnets ── NAT gateway (egress only)                    │
   │                                                                  │
   │   private subnets (NO public IP):                                │
   │     jumpbox  ── runs the sky CLI; reaches the rest over          │
   │        │         DIRECT private-IP SSH (use_ssm: false)          │
   │        ├──► jobs controller ──► GPU workers / vLLM replicas      │
   │        └── S3 gateway endpoint, SSM interface endpoints          │
   └──────────────────────────────────────────────────────────────────┘
```
- **Everything runs in private subnets** - no public IP, no inbound SSH.
- **You run sky on the jumpbox, not your laptop.** The jumpbox is inside the VPC,
  so SkyPilot connects to the controller and workers over **direct private-IP SSH**
  with `use_internal_ips: true` + `use_ssm: false`. This is the configuration
  proven to work; see `how-it-works.md` for why SSM from an in-VPC client fails.
- **You reach the jumpbox over SSM** (interactive shell to run sky, and
  port-forward to test a served model). That is what the `ssm` / `ssmmessages` /
  `ec2messages` interface endpoints are for; it also works over the NAT gateway.
- **NAT gateway** (1 per VPC) gives nodes egress for pip / Hugging Face / Docker.
- **You reach a served model** by tunneling through the jumpbox to the replica's
  private IP (`infra/jumpbox/connect.sh`).

> Cross-region path: direct private-IP SSH works within a VPC because the jumpbox,
> controller, and workers share it. If a managed job's worker lands in **another
> region**, the controller reaches it only if the VPCs are **peered**. `infra/peering`
> ships this (hub-and-spoke from the primary VPC to each secondary, with routes both
> ways); the non-overlapping CIDRs below are its prerequisite. Serving replicas
> (03/04) stay within one region and need no peering. See `how-it-works.md`.

### Why a named VPC is mandatory
Sandbox accounts often have **no default VPC** in a region. Without an
explicit VPC, SkyPilot's spot launch there fails (`default VPC ... does not exist`)
and that can abort the whole failover chain. So every recipe relies on
`aws.vpc_name` pointing at a real VPC that exists in each candidate region. Run
`scripts/preflight.sh` to verify this before launching.

### Give each region a distinct CIDR
The per-region VPCs each need their **own, non-overlapping CIDR** if you ever want
to peer them or attach them to a Transit Gateway - overlapping ranges can't be
connected, and a VPC's CIDR can't be changed after creation without a rebuild.
`infra/vpc/README.md` has a non-overlapping default set (10.10/16, 10.11/16, ...);
pass each to Terraform with `-var="vpc_cidr=..."` when you apply per region. A
shared CIDR only works for a single isolated test VPC.

## Data and weights flow (training)
```
   S3 training bucket (region-local)      S3 weights bucket (region-local)
   skyspot-training-<acct>-<region>       skyspot-weights-<acct>-<region>
            │ aws s3 sync -> /data                  ▲ periodic sync of /outputs
            v                                        │
        GPU node: train.py  ── checkpoints + final adapter ──┘
```
Buckets are **region-suffixed** so the same deployment works in every region. The
recipe does not hardcode a bucket: at launch it reads the region it landed in (from
instance metadata) and composes `<prefix>-training|weights-<account>-<region>`.

- **Input**: the run script `aws s3 sync`s the region-local training bucket to
  `/data`. The training data is put in the primary bucket once and copied to the
  other regions by **cross-region replication** (`infra/data-replication`), so this
  read is always local.
- **Output**: `train.py` writes checkpoints + the final adapter to `/outputs`, which
  a background loop syncs to the region-local weights bucket every ~2 minutes (and
  once more at the end) - so a spot preemption keeps finished work. Final weights:
  `s3://skyspot-weights-<account>-<region>/runs/<run-id>/`.

> Why sync and not an S3 MOUNT? A static mount would pin one bucket (one region)
> into the recipe, defeating failover. Resolving the region at runtime lets the one
> recipe read and write locally wherever it lands.

## Spot failover
`job_recovery: EAGER_NEXT_REGION` (training) and SkyServe's replica management
(serving) handle preemption: on loss, SkyPilot re-provisions, eagerly trying the
next region rather than waiting for the same one to recover. `max_hourly_cost`
keeps every attempt under budget.

## Instance choices
| Recipe | Workload | GPUs | Instances |
|--------|----------|------|-----------|
| 01 | single-GPU fine-tune | 1 | g7e / g6 / g5 (1-GPU sizes) |
| 02 | multi-GPU fine-tune | 8 (1 node) | g7e.48xlarge / g6.48xlarge / g5.48xlarge |
| 03 | serve small LLM | 1 | g7e / g6 / g5 (1-GPU sizes) |
| 04 | serve large LLM | 16 (2 nodes) | p5en (H200 x8) x2 (`.48xlarge`) + EFA |

GPU map: g7e = RTX PRO 6000 (96GB), g6 = L4 (24GB), g5 = A10G (24GB),
p5en = H200 (141GB), p5 = H100 (80GB), p6-b200 = B200 (192GB), p6-b300 = B300 (~288GB).
Recipe 04 standardizes on 2x 8x H200 for GLM-5.3 (~1.5 TB BF16); B200 is a valid
2-node alternative, B300 would be a single node (a separate recipe).
