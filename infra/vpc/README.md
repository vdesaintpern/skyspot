# infra/vpc - standard SkySpot VPC (optional, one per region)

Creates the VPC SkyPilot launches into: all AZs, private-only workloads, 1 NAT
gateway, an S3 gateway endpoint, and the SSM interface endpoints that let
SkyPilot reach private nodes over Session Manager.

Run this **once per region** a recipe's `any_of:` lists. Skip it if the
customer already has VPCs - just point `aws.vpc_name` at an existing one and make
sure it has private subnets with NAT egress and SSM reachability.

## Why you need it
Sandbox accounts often have no default VPC in a region. SkyPilot then
fails every spot launch there and aborts the failover chain. A named VPC per
region fixes that (see `../../docs/architecture.md`).

## Choose a CIDR per region FIRST (important)
The default CIDR is `10.10.0.0/16`. That is fine for a single, isolated test VPC.
But if you ever want to **peer** these VPCs or attach them to a **Transit Gateway**
(to reach them from a shared network, or let them reach each other), their CIDRs
**must not overlap** - peering/TGW simply refuse overlapping ranges, and you
cannot change a VPC's CIDR after the fact without rebuilding.

So give each region a **distinct** CIDR, passed as `-var="vpc_cidr=..."` on each
apply. A safe, non-overlapping starting set:

| Region | Suggested CIDR |
|--------|----------------|
| eu-north-1 | 10.10.0.0/16 |
| ap-south-1 | 10.11.0.0/16 |
| us-east-1  | 10.13.0.0/16 |
| eu-west-2  | 10.14.0.0/16 |

## Apply (per region)
Use a separate workspace per region so the states don't clobber each other, and
pass that region's CIDR:
```bash
cd infra/vpc
terraform init

terraform workspace new eu-north-1
terraform apply -var="region=eu-north-1" -var="vpc_cidr=10.10.0.0/16"

terraform workspace new ap-south-1
terraform apply -var="region=ap-south-1" -var="vpc_cidr=10.11.0.0/16"

terraform workspace new us-east-1
terraform apply -var="region=us-east-1" -var="vpc_cidr=10.13.0.0/16"
```

## Bring your own VPC instead
If the customer already has suitable VPCs, skip this stack: make sure each existing
VPC's `Name` tag equals `aws.vpc_name` (default `skyspot-vpc`) so SkyPilot finds it.
It needs private subnets with NAT egress and SSM reachability (see the main README).

## After apply
1. Deploy the jumpbox (`../jumpbox`) - it runs sky and writes `~/.sky/config.yaml`
   for you (direct-SSH, `use_ssm: false`). `terraform output sky_config_snippet`
   shows the equivalent `aws:` block for reference.
2. Note `terraform output vpc_id` if you want a record of what was created.
3. Run `../../scripts/preflight.sh` to confirm the VPC exists in every region.

## Cost note
The NAT gateway bills hourly + per GB even when idle. Destroy the VPCs when you
are done evaluating:
```bash
terraform destroy -var="region=eu-north-1"   # repeat per region/workspace
```
Destroy the `jumpbox` stack and tear down any live SkyPilot clusters/services
FIRST - their ENIs and security groups live in this VPC and will block the destroy.
