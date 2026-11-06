# infra/jumpbox - SkyPilot control host (and inference-test tunnel)

A small box (`t3.medium`) in a private subnet of the SkySpot VPC, reachable only
through AWS Systems Manager Session Manager. It plays two roles:

1. **SkyPilot control host.** You run the `sky` CLI *here*, not on your laptop.
   Because the jumpbox is inside the VPC, SkyPilot reaches the controller and
   workers over **direct private-IP SSH** (`use_ssm: false`) - the configuration
   proven to work. (Running sky from your laptop would force SSM for the
   controller->worker hop, which fails; see `../../docs/how-it-works.md`.)
2. **Inference tunnel.** Port-forward from your laptop through the jumpbox to a
   served model's private endpoint, to `curl` it locally.

```
laptop --SSM--> jumpbox (runs sky) --private-IP SSH--> controller / workers
laptop:8000 --SSM--> jumpbox --private VPC--> vLLM server:8000   (testing)
```

sky is **pre-installed and configured** on first boot (see `bootstrap.sh.tftpl`):
an isolated venv at `/opt/sky`, on PATH, with `/root/.sky/config.yaml` set to
`vpc_name` + `use_internal_ips: true` + `use_ssm: false`.

## Prereqs
- The SkySpot VPC exists in this region (`../vpc`).
- AWS CLI v2 and `session-manager-plugin` installed locally (for SSM).

## Apply
```bash
cd infra/jumpbox
terraform init
terraform apply -var="region=eu-north-1"
```
The jumpbox role is granted SkyPilot's AWS permissions (EC2/S3 + manage/pass the
`skypilot-v1` role). Give the bootstrap ~2-3 min after apply to finish installing.

## Run SkyPilot from the jumpbox
```bash
# open an interactive shell on the jumpbox
aws ssm start-session --target "$(terraform output -raw instance_id)" --region eu-north-1

# on the jumpbox (sky is on PATH):
sky check aws
# get the recipes onto the jumpbox (clone your repo, or scp), then from the repo root:
sky jobs launch -n ft recipes/01-finetune-single-gpu/finetune.sky.yaml -y
```
The recipe files must be present on the jumpbox (its `workdir` is uploaded to the
worker). Clone the repo on the jumpbox, or copy the recipe folder over.

## Inference tunnel (testing a served model)
```bash
# model's private IP (from the jumpbox): sky serve status <name> / sky status --ip <cluster>
./connect.sh "$(terraform output -raw instance_id)" <model-private-ip> 8000 8000 eu-north-1
# then, locally:
curl http://localhost:8000/v1/models
```

## Teardown
```bash
terraform destroy -var="region=eu-north-1"
```
Destroy the jumpbox BEFORE the VPC (its ENI/SG live in the VPC). If a SkyPilot
controller is still up, tear it down first from the jumpbox
(`sky down sky-jobs-controller-<hash>`), and delete any leftover `sky-sg-*`
security groups before the VPC destroy (see the main README Cleanup section).
