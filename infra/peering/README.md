# infra/peering - inter-region VPC peering (multi-region only)

Connects the per-region SkySpot VPCs so the SkyPilot **jobs controller** (in the
primary region) can reach a managed-job **worker that failed over to another
region** over direct private-IP SSH. Needed only for multi-region managed jobs
(recipes 01/02). Single-region and serving-only (03/04) setups do not need it.

What it creates (hub-and-spoke, primary at the hub):
- a VPC peering connection from the **primary** VPC to each **secondary** VPC,
  accepted cross-region, and
- routes in every VPC's **private** route tables to the peer's CIDR (both ways).

Secondaries are not peered to each other: one managed job runs in one region at a
time, so the controller only needs a path to wherever the current worker landed.

## Prerequisites
- A `skyspot-vpc` already deployed in all three regions (`infra/vpc`), each with a
  **distinct, non-overlapping CIDR** - overlapping ranges cannot be peered.

## Apply
```bash
cd infra/peering
terraform init
terraform apply \
  -var="primary_region=eu-north-1" \
  -var="secondary_region_1=ap-south-1" \
  -var="secondary_region_2=us-east-1"
```
`terraform output vpc_cidrs` shows the discovered CIDRs - confirm they do not
overlap.

## Security groups
SkyPilot creates its own per-cluster security groups (`sky-sg-*`) that this stack
does not manage. SkyPilot's default allows SSH, so the routes created here are
normally all that is needed for the controller to reach a cross-region worker. If
you lock SkyPilot's SG down, also allow inbound TCP 22 from the primary VPC CIDR on
the worker side.

## Verifying it works
Launch a managed job pinned to a **secondary** region while the controller lives in
the primary - that forces a cross-region controller->worker hop:
```yaml
# temporarily, in the recipe:
any_of:
  - {cloud: aws, region: ap-south-1}
```
If the job provisions and streams logs (rather than hanging on SSH), peering is
working.

## Teardown
```bash
terraform destroy \
  -var="primary_region=eu-north-1" \
  -var="secondary_region_1=ap-south-1" \
  -var="secondary_region_2=us-east-1"
```
Destroy this **before** the VPCs (the routes live in the VPC route tables).
