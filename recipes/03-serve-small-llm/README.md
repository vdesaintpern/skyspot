# Recipe 03 - serve a small LLM on spot (Qwen3.5-4B + vLLM)

A single-GPU vLLM server exposed through SkyServe, on spot with an on-demand
fallback replica so the endpoint survives preemptions.

## Deploy
```bash
sky serve up -n qwen recipes/03-serve-small-llm/serve.sky.yaml
sky serve status qwen      # wait until a replica is READY
```
`sky serve status` prints the service **endpoint** and each replica's cluster.

## Test it (private VPC -> tunnel)
The replica has no public IP (private subnets). Tunnel to it through the jumpbox
(`../../infra/jumpbox`), then call the OpenAI-compatible API locally:
```bash
# get the replica's private IP
sky status --ip <replica-cluster-name>

# open the tunnel (separate terminal)
../../infra/jumpbox/connect.sh $(cd ../../infra/jumpbox && terraform output -raw instance_id) \
  <replica-private-ip> 8000 8000 eu-north-1

# call the model
curl http://localhost:8000/v1/models
curl http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen3.5-4B","messages":[{"role":"user","content":"Say hi in French."}]}'
```

## Notes
- `tensor-parallel-size = $SKYPILOT_NUM_GPUS_PER_NODE` -> 1 on the single-GPU
  sizes here. 96GB (g7e) / 24GB (g6, g5) all hold a 4B model easily.
- `dynamic_ondemand_fallback: true` runs the replica on spot and only spins an
  on-demand replica if spot cannot be provisioned. Set it `false` for pure spot
  (cheaper, but the endpoint can briefly go unavailable during a preemption +
  relaunch).
- To autoscale, raise `replica_policy.max_replicas` **and** set
  `target_qps_per_replica` (required whenever min != max).

## Teardown
```bash
sky serve down qwen
```
