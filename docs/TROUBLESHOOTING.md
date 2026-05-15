# Troubleshooting transcript

This file records the 2026-05-15 troubleshooting session after commit `3f68adf` (`Improve Anyscale AKS deployment diagnostics`). The focus was local troubleshooting tool setup plus diagnosis of the declarative CPU workspace behavior on the private AKS deployment.

## Environment snapshot

- Subscription: `24a4c592-bfaf-492f-beaf-f10b3b67f03f`
- Tenant: `6f070e41-8d1e-45c9-af17-551c9b98860d`
- Resource group: `rg-anyscale99-dev-wus3`
- AKS cluster: `aks-anyscale99-dev-wus3`
- Region: `westus3`
- Bastion-backed kubeconfig: `.cache/aks-anyscale-sample-harness/kubeconfig.bastion`
- CPU workspace: `aks-cpu-workspace`
- GPU workspace: `aks-gpu-workspace`
- Direct `anyscale` CLI note: source `.env` first with `set -a; source .env; set +a`

## Tooling installed during this session

### AKS MCP

Purpose: expose AKS-aware MCP tools to Copilot Chat, the `copilot` CLI, and `gh copilot`.

Installed on macOS `darwin-arm64`:

```bash
curl -L -o "$TMPDIR/aks-mcp.tar.gz" \
  https://github.com/Azure/aks-mcp/releases/download/v0.0.17/aks-mcp-darwin-arm64.tar.gz
tar -xzf "$TMPDIR/aks-mcp.tar.gz" -C "$TMPDIR"
install "$TMPDIR/aks-mcp-darwin-arm64/aks-mcp" /opt/homebrew/bin/aks-mcp
```

Local registration files were created as workstation-only config because both are gitignored in this repository:

- `.vscode/mcp.json` for Copilot Chat in VS Code
- `.mcp.json` for `copilot` and `gh copilot`

Verification:

```bash
copilot mcp get aks
gh copilot -- mcp get aks
```

Result: both clients resolved the local `aks` MCP server entry successfully.

### AKS Agentic CLI

Purpose: Azure CLI extension for agent-guided AKS troubleshooting.

Installed with:

```bash
az extension add --name aks-agent --upgrade
az aks agent --help
```

Result: the preview extension installed and the command surface was available. Limitation observed during this session: Docker was not installed on the local macOS workstation, so the local containerized client mode was not exercised further.

### Inspektor Gadget

Purpose: live cluster and kernel troubleshooting, including process snapshots and network inspection.

Installed and deployed with:

```bash
eval "$(./scripts/setup.sh kubeconfig-bastion --export)"
kubectl krew install gadget
kubectl-gadget deploy --timeout 4m
```

Result: the DaemonSet in namespace `gadget` reached `5/5` ready pods. Operational note: the direct `kubectl-gadget` binary was more reliable than plugin discovery through `kubectl gadget` in this environment.

## Declarative CPU workspace investigation

### Starting hypothesis

The working hypothesis was that the declarative CPU workspace might be missing a required taint or toleration, preventing the `cpu-workers` group from scheduling cleanly.

### Cached `/tmp` search

Searched the cached artifacts under `/tmp` with:

```bash
rg -n -i 'taint|toleration|nodeSelector|cpu-workers|gpu-workers|required_resources|agentpool' /tmp
```

Findings:

- The cached material only referenced GPU-specific toleration patches.
- `/tmp/anyscale-workspaces-register-20260515.log` confirmed the operator GPU toleration patch was applied.
- The cached Terraform plan showed tolerations for ingress-nginx and the NVIDIA device plugin, both keyed to GPU or capacity-type scenarios.
- No cached Anyscale artifact in `/tmp` described an additional CPU-only taint or toleration requirement.

## Live placement checks

The live CPU worker pod was inspected directly.

Compact placement query:

```bash
kubectl get pod -n anyscale-operator "$WORKER_POD" \
  -o jsonpath='{.spec.nodeSelector}{"\n"}{.spec.tolerations}{"\n"}{.status.phase}{"\n"}{range .status.containerStatuses[*]}{.name}{":ready="}{.ready}{",started="}{.started}{"\n"}{end}'
```

Observed values:

```text
{"agentpool":"cpu"}
[{"effect":"NoSchedule","key":"node.anyscale.com/capacity-type","value":"ON_DEMAND"},{"effect":"NoExecute","key":"node.kubernetes.io/not-ready","operator":"Exists","tolerationSeconds":300},{"effect":"NoExecute","key":"node.kubernetes.io/unreachable","operator":"Exists","tolerationSeconds":300},{"effect":"NoSchedule","key":"node.kubernetes.io/memory-pressure","operator":"Exists"}]
Running
activity-probe:ready=true,started=true
anyscaled:ready=true,started=true
ray:ready=true,started=true
vector:ready=true,started=true
```

The corresponding AKS node showed no taints:

```bash
kubectl get node aks-cpu-33215742-vmss000001 -o json | \
  jq '{name:.metadata.name,taints:(.spec.taints // []),agentpool:.metadata.labels["kubernetes.azure.com/agentpool"]}'
```

```json
{
  "name": "aks-cpu-33215742-vmss000001",
  "taints": [],
  "agentpool": "cpu"
}
```

The current pod placement also matched the expected CPU pool:

```bash
kubectl get pods -n anyscale-operator -l 'app.kubernetes.io/name=aks-cpu-workspace' -o wide
```

```text
NAME                  READY   STATUS    RESTARTS   AGE     IP            NODE
k-18c52585abce30000   7/7     Running   0          128m    10.50.4.144   aks-cpu-33215742-vmss000000
k-9bbc4c4c17aa80000   5/5     Running   0          9m17s   10.50.4.162   aks-cpu-33215742-vmss000001
```

Interpretation: the worker is landing on the intended `cpu` pool and the node itself is untainted. A missing CPU toleration is not supported by the live data.

## Direct Ray probes

The direct CPU probe used in the workspace head pod was:

```python
import ray

ray.init(address="auto")

@ray.remote(num_cpus=1)
def cpu_probe():
    return "CPU_WORKSPACE_OK"

print(ray.get(cpu_probe.remote(), timeout=180))
```

Observed sequence:

1. The first direct `num_cpus=1` task timed out while the workspace was still scaling from zero.
2. After that demand was introduced, `ray status` showed the `cpu-workers` group coming up.
3. Once the worker was ready, the same probe returned `CPU_WORKSPACE_OK`.

Successful re-test output:

```text
CPU_WORKSPACE_OK
```

Final `ray status` snapshot:

```text
======== Autoscaler status: 2026-05-15 14:04:52.051826 ========
Node status
---------------------------------------------------------------
Active:
 (no active nodes)
Idle:
 1 head
 1 cpu-workers
Pending:
 (no pending nodes)
Recent failures:
 (no failures)

Resources
---------------------------------------------------------------
Total Usage:
 0.0/8.0 CPU
 0.0/2.0 anyscale/cpu_only:true
 0.0/1.0 anyscale/node-group:cpu-workers
 0.0/1.0 anyscale/node-group:head
 0.0/2.0 anyscale/provider:azure
 0.0/2.0 anyscale/region:westus3
 0B/64.00GiB memory
 0B/17.89GiB object_store_memory

From request_resources:
 (none)
Pending Demands:
 (no resource demands)
```

## Conclusion

- The declarative CPU workspace issue was not caused by missing CPU taints or tolerations.
- The reproducible failure mode was scale-from-zero latency: the first `num_cpus=1` task can time out before the new `cpu-workers` node finishes joining Ray.
- Once the worker is ready, the same probe succeeds without changing the compute config or pod placement rules.

## Practical operator guidance

- When a cold CPU workspace looks stuck, check `ray status` from the head pod before changing selectors or tolerations.
- If `ray status` shows the worker group coming up, rerun the CPU probe after the worker reaches `Running` and appears as idle in Ray.
- Prefer the direct `kubectl-gadget` command in this environment.
