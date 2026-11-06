# Recipe 04 - serve a large multi-node LLM on spot (GLM-5.3 + vLLM + EFA)

GLM-5.3 is **~1.5 TB in BF16**, too big for a single 8-GPU node here, so each
replica is a **2-node** cluster of **8x H200** (`p5en.48xlarge`) joined by **EFA**,
running vLLM over Ray.

## Why this one is different
- **Not a G instance** (requirement): uses Hopper **H200** (`p5en`) - the GPU with
  the memory and EFA fabric a model this size needs.
- **`network_tier: best`** turns on EFA so the two nodes talk at full "same spine"
  bandwidth - this is what makes cross-node parallelism viable.
- **Parallelism**: tensor-parallel within each node (`$SKYPILOT_NUM_GPUS_PER_NODE`
  = 8), pipeline-parallel across the nodes (`$SKYPILOT_NUM_NODES` = 2). SkyPilot
  builds the Ray cluster; node 0 runs the vLLM server, the worker joins Ray.

## Sizing: why 2x 8x H200
GLM-5.3 weights are ~1.5 TB in BF16, plus KV cache and activation headroom. Per
8-GPU node memory (GPU mem x 8):

| GPU (8/node) | Node memory | Nodes for GLM-5.3 |
|--------------|------------:|:-----------------:|
| H200 (`p5en.48xlarge`) | ~1.1 TB | **2** (this recipe) -> ~2.26 TB |
| B200 (`p6-b200.48xlarge`) | ~1.5 TB | 2 -> ~3.0 TB (valid alternative) |
| H100 (`p5.48xlarge`) | 0.64 TB | 3 (2 nodes = 1.28 TB < 1.5 TB, too small) |
| B300 (`p6-b300.48xlarge`) | ~2.3 TB | 1 (single node - different topology) |

This recipe standardizes on **2x H200**. `num_nodes` is a task-level setting in
SkyPilot (it cannot vary per GPU type), so a single-node B300 deployment would be a
**separate** recipe, not a variant of this one. To widen spot capacity you may add
B200 to `accelerators` (it is also a 2-node fit): `accelerators: {H200:8, B200:8}`.

## Capacity reality (read before launching)
Large P5/P6 spot capacity is **scarce and quota-gated**:
- **Spot quota** is the aggregate "All P Spot Instance Requests" (vCPUs). A 2-node
  H200 replica is 2 x 192 = **384 vCPU**; the default P-spot quota (768 vCPU in the
  regions here) covers it with no increase. The **on-demand** fallback uses a
  *separate* on-demand P quota that often starts at **0** - request an increase if
  you want the fallback to work.
- Quota is not capacity: a launch can still fail `InsufficientInstanceCapacity`,
  and two 8-GPU nodes in the same AZ with EFA placement is a demanding ask on spot.
- **Regions**: H200 (`p5en`) is offered in **eu-north-1** and **ap-south-1** in this
  set. You need a SkySpot VPC in every region kept in `any_of:` (`../../infra/vpc`).
- Both nodes of a replica land in **one** region (same VPC; EFA needs the same AZ /
  placement group) - no cross-region peering is involved.
- **Disk and first-load time scale with the model.** A ~1.5 TB model must fit the
  node boot disk (`resources.disk_size`, set to 2000 GB here) and takes far longer
  to download and load than a small one, so the readiness window is raised to 2h
  (`service.readiness_probe.initial_delay_seconds`). Both are in the YAML with
  comments; tune them to your model. Too small a disk fails with "No space left on
  device"; too short a window fails a healthy replica mid-load.

## Deploy
```bash
sky serve up -n glm recipes/04-serve-large-llm-multinode/serve.sky.yaml
sky serve status glm       # wait for READY (first load of a large model is slow)
sky serve logs glm 1
```

## Test it
Same pattern as recipe 03. `sky serve status glm` prints the service **endpoint**
(the load balancer on the serve controller, `<ctrl-ip>:30001`). From the in-VPC
jumpbox you can curl it directly; from your laptop, tunnel through the jumpbox with
`connect.sh` pointed at the serve-controller endpoint, then:
```bash
curl http://<endpoint>/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"zai-org/GLM-5.3","messages":[{"role":"user","content":"Hello"}]}'
```

## Teardown
```bash
sky serve down glm         # removes the service + both-node replica
```
SkyServe also leaves a **serve controller** running (a separate small instance that
autostops when idle). To remove it entirely: find it with `sky status`, then
`sky down sky-serve-controller-<hash>` (you will be prompted to type `delete`).
