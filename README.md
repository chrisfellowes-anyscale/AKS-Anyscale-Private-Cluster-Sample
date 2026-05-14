# Private AKS foundation for Anyscale on Azure

This repository builds a private Azure landing zone for running Anyscale on AKS. The stack creates the network, Azure Bastion host, Azure Firewall egress path, DNS Private Resolver, private AKS cluster, private storage account, private Azure Container Registry, Log Analytics and Container Insights wiring, and the user-assigned managed identity that the Anyscale operator uses for Azure data-plane access. It also includes the shell workflow that turns a private cluster into something an operator can deploy, validate, and smoke-test from a local machine without exposing the Kubernetes API publicly.

This is an infrastructure and operator workflow repository, not an application repository and not a self-hosted Anyscale control plane. The cluster runs the operator and workloads, while the Anyscale console remains SaaS-hosted at `https://console.azure.anyscale.com`.

## Architecture

![Private AKS architecture for Anyscale on Azure](docs/architecture.svg)

The editable source for the diagram is `docs/architecture.drawio`. If you change it, regenerate the checked-in SVG with `bash scripts/export-diagrams.sh`.

## What this deployment creates

Phase 1 creates the Azure foundation: the resource group, VNet, Bastion subnet, AKS API server subnet, AKS node subnet, private endpoint subnet, DNS Private Resolver subnets, Azure Firewall subnets and policy, the private AKS cluster with system, CPU, and GPU pools, the private storage account, the private Premium ACR, the operator managed identity and federated identity wiring, and the observability resources. Phase 2 finishes the Kubernetes side of the deployment by applying the Terraform-managed bootstrap layer through a Bastion-backed kubeconfig, deploying the Azure-native Anyscale cloud resources through AzAPI, and installing the AKS marketplace extension through the native `azurerm_kubernetes_cluster_extension` resource so the existing AKS cluster, storage account, registry, and operator identity are bound into the Anyscale platform flow.

The result is intentionally opinionated. AKS stays private, the storage account and ACR stay private-only through Private Link, node egress is forced through Azure Firewall, DNS resolution follows the same enterprise path that the firewall enforces, and local Kubernetes access is Bastion-first.

## Prerequisites

You should assume this README is the only document you need to get a fresh environment running, so start by making sure the local workstation, Azure permissions, and Anyscale inputs are in place before you touch Terraform.

For the local workstation, work from a macOS or Linux shell with Git, Azure CLI, Terraform `>= 1.9.0`, `kubectl`, `kubelogin`, `helm`, `jq`, Python `3.9+`, and `uv` installed. The private-cluster workflow also requires the Azure CLI `aks-preview` and `bastion` extensions. If you want to regenerate the architecture preview, install the draw.io or diagrams.net CLI as well.

For Azure access, you need to be able to log in to the target tenant and subscription and create the full set of resources this stack uses: networking, Azure Firewall, Azure Bastion, AKS, Private Link, storage, ACR, Log Analytics, managed identities, federated identity credentials, and RBAC assignments. If the target subscription has not already accepted the Anyscale marketplace offer, it also needs permission to create or accept that agreement during the phase-2 deployment. The sample configuration assumes GPU quota for `Standard_NC16as_T4_v3` in the target region because the default validated path keeps one T4 node warm for workspace and smoke-test bring-up.

For Anyscale access, the infrastructure deployment itself does not require an API token, but the post-deploy helper commands do. `./scripts/setup.sh anyscale-workspace-ready`, `./scripts/setup.sh anyscale-workspaces-register`, and the new guided `./scripts/setup.sh deploy-part2` flow all require `ANYSCALE_CLI_TOKEN` in `.env`, and they also expect the repo-local CLI binary at `.venv/bin/anyscale`. Current Anyscale documentation says service accounts can be created with CLI, but service-account API keys are still created in the Anyscale console, so the guided repo automation intentionally splits the operator path into part 1 and part 2 around that manual handoff.

## Start from a fresh clone

After cloning the repository, work from the repository root and create a local `.env` from the committed template.

```bash
cp .env-template .env
```

The `.env-template` file is the source of truth for required inputs, and it is intentionally verbose. In practice you need to provide the Azure subscription and tenant IDs, choose the naming and region values, confirm the VNet and subnet CIDRs, review the outbound allowlists, replace the placeholder ownership tags, and decide whether the default AKS and GPU settings are acceptable in your region. The defaults are opinionated on purpose: they pin AKS to `1.34.6`, keep the GPU pool at `min_count=1`, enable Azure Monitor diagnostics, and default the operator identity mode to `{"mode":"create"}`.

The Anyscale section of `.env` is much smaller than it first appears. `ANYSCALE_CLOUD_NAME` is derived from the deployed Azure resource name when it is blank, `ANYSCALE_CLOUD_DEPLOYMENT_ID` is discovered from the live platform deployment after phase 2 completes, and `ANYSCALE_CLI_TOKEN` is the only value you normally supply yourself. You can leave `ANYSCALE_CLI_TOKEN` blank for the Terraform phases and fill it in only when `./scripts/setup.sh deploy-part1` stops after phase 2 and tells you to continue with `./scripts/setup.sh deploy-part2`. The default authentication path for Terraform is `ARM_USE_CLI=true`, which means the wrapper assumes a normal local `az login`. If you need service principal, OIDC, or managed identity auth instead, the commented `ARM_*` settings in `.env-template` are the place to start.

The wrapper renders `infra/terraform/terraform.auto.tfvars.json` from `.env`. You can do that explicitly with `./scripts/setup.sh tfvars`, but every major wrapper command also re-renders it automatically, so the dedicated command is mostly useful when you want to inspect the generated JSON after editing `.env`.

Before you deploy anything, source the environment file for convenience and authenticate Azure CLI against the target tenant.

```bash
source .env
az login --tenant "$TF_VAR_azure_tenant_id"
```

The wrapper will set the active subscription from `.env` during preflight, so you do not need to do that by hand unless you want to.

## Install the repo-local Anyscale CLI

If you plan to use the Anyscale post-configuration helpers or the workspace smoke test, create the repo-local virtual environment before phase 2 so `./scripts/setup.sh apply` can auto-run the operator patch when the rest of the prerequisites are already present.

```bash
uv venv .venv
source .venv/bin/activate
UV_CACHE_DIR="$PWD/.cache/uv-cache" uv pip install --python .venv/bin/python anyscale
```

If you want an interactive CLI session for manual exploration, you can run `.venv/bin/anyscale login`. That is useful for ad hoc inspection, but it does not replace `ANYSCALE_CLI_TOKEN` for `anyscale-workspace-ready`, `anyscale-workspaces-register`, or `deploy-part2`; those helpers read the token from `.env` and fail fast when it is missing. The guided `deploy-part1` orchestration pauses before those steps, and `deploy-part2` still expects the repo-local CLI binary at `.venv/bin/anyscale`.

## Understand the deployment flow before you start

This repository uses a two-phase deployment on purpose. The Azure infrastructure, private AKS cluster, storage, registry, identity, networking, and observability resources can be created without local Kubernetes access, but the Terraform-managed bootstrap layer and the Anyscale platform deployment need a working path to the private AKS API. That path is provided by Azure Bastion and a Bastion-backed kubeconfig that points Terraform, `kubectl`, and `helm` at a local tunnel rather than at the private AKS DNS name directly.

The wrapper includes `./scripts/setup.sh all`, but that command only covers the Terraform portion of the workflow. For this repository, the simplest supported guided path is `./scripts/setup.sh deploy-part1 --from-scratch --yes`, then after the manual token handoff `./scripts/setup.sh deploy-part2`. After the initial bring-up, `deploy-part2` is the preferred idempotent reconciliation command to rerun when you change phase-2 Terraform, operator settings, or workspace registration behavior. The explicit phase-1 and phase-2 sequence below remains the manual equivalent when you want tighter control over each step.

## Guided two-step orchestration with token handoff

If you want the repository to drive the full deployment and make the operator handoff dead simple, use the two-step wrapper.

```bash
./scripts/setup.sh deploy-part1 --from-scratch --yes
```

Part 1 runs `nuke`, `preflight`, `init`, `validate`, the phase-1 Terraform deployment, the Bastion tunnel and Bastion-backed kubeconfig handoff, and the phase-2 Terraform deployment. It then stops on purpose and writes the exact handoff to `.cache/aks-anyscale-sample-harness/deploy-e2e.pause.txt` so you can do the one remaining manual step. If you rerun part 1 against an environment where the target AKS cluster already exists, it skips the destructive phase-1 toggle apply and just reconciles phase 2 before stopping again at the handoff.

This is the required workaround for the current Anyscale auth gap: let the script provision everything it can, stop after phase 2, add `ANYSCALE_CLI_TOKEN` to `.env` from the Anyscale console, then continue with part 2.

At the pause point, update only `ANYSCALE_CLI_TOKEN` in `.env` and then run:

```bash
./scripts/setup.sh deploy-part2
```

Part 2 reuses or restarts the Bastion tunnel, reruns `terraform init` and the repository validation checks, exports a Bastion-backed kubeconfig, reapplies the phase-2 Terraform configuration, patches the live `anyscale-operator` release, and runs `anyscale-workspaces-register` to create or reuse the durable CPU and GPU workspaces. When it finishes, it prints that you are ready to go with a workspace that has CPU and GPU configs ready.

In practice, once part 1 has established the environment and you have supplied `ANYSCALE_CLI_TOKEN`, `./scripts/setup.sh deploy-part2` is the command you can keep rerunning after changes. That is the supported idempotent path for reconciling phase-2 infrastructure plus the Anyscale operator and workspace state.

The older `./scripts/setup.sh deploy-e2e --from-scratch --yes` plus `./scripts/setup.sh deploy-e2e --resume` flow still works as a compatibility wrapper, but `deploy-part1` and `deploy-part2` are now the primary operator path.

## Phase 1: build the Azure foundation and private AKS cluster

Start by validating the workstation and the Terraform inputs, then run a phase-1 plan and apply with the Kubernetes bootstrap layer and Anyscale platform deployment disabled.

```bash
source .env
az login --tenant "$TF_VAR_azure_tenant_id"

./scripts/setup.sh preflight
./scripts/setup.sh init
./scripts/setup.sh validate

export TF_VAR_cluster_bootstrap='{"enabled":false}'
export TF_VAR_anyscale_platform='{"enabled":false}'

./scripts/setup.sh plan
./scripts/setup.sh apply
./scripts/setup.sh outputs
```

`preflight` checks the required CLI tools, renders `terraform.auto.tfvars.json`, verifies `az login`, and switches Azure CLI to the subscription named in `.env`. `init` performs `terraform init`. `validate` runs `terraform fmt -check`, `terraform validate`, and the plan-time Terraform tests that assert the private-cluster, identity, firewall, DNS, observability, and native-extension contracts. The phase-1 `plan` and `apply` then create the Azure side of the deployment without attempting the Bastion-backed bootstrap, the Anyscale cloud deployment, or the marketplace extension install.

When phase 1 completes successfully, you should have a live resource group, private AKS cluster, Bastion host, Azure Firewall, DNS resolver, private storage and registry, operator identity, and observability resources. What you do not have yet is the Kubernetes bootstrap layer inside the cluster, the Anyscale cloud deployment, or the AKS marketplace extension install, because all three belong to phase 2.

## Phase 2: connect through Bastion and finish the deployment

Phase 2 starts by opening a reusable Bastion tunnel, exporting a Bastion-backed kubeconfig, and then re-running Terraform with `cluster_bootstrap.kubeconfig_path` pointed at that kubeconfig. That is the handoff that lets the Terraform Kubernetes and Helm providers work against a private cluster from a local machine.

```bash
./scripts/setup.sh bastion-tunnel start
eval "$(./scripts/setup.sh kubeconfig-bastion --export)"

unset TF_VAR_anyscale_platform
export TF_VAR_cluster_bootstrap="{\"kubeconfig_path\":\"${KUBECONFIG}\"}"

./scripts/setup.sh plan
./scripts/setup.sh apply
./scripts/setup.sh outputs
./scripts/setup.sh status
```

The Bastion helper writes the reusable tunnel state, kubeconfigs, and logs under `.cache/`, which is intentionally ignored by Git. `kubeconfig-bastion` fetches the normal AKS credentials, rewrites the kubeconfig server to the local Bastion listener, preserves the original TLS server name, and prints the `export KUBECONFIG=...` line that `eval` applies to the current shell.

During phase 2, `plan` and `apply` also reconcile marketplace and platform state. If the Anyscale marketplace agreement or the Azure deployment already exists outside Terraform state, the wrapper imports them before continuing. When the apply succeeds, the wrapper also syncs `ANYSCALE_CLOUD_NAME` and `ANYSCALE_CLOUD_DEPLOYMENT_ID` back into `.env` so later Anyscale CLI commands can use the deployed cloud metadata without manual copy and paste.

If the current shell already has a Bastion-backed kubeconfig, `ANYSCALE_CLI_TOKEN`, `.venv/bin/anyscale`, `kubectl`, `kubelogin`, `helm`, and `jq`, the phase-2 `apply` automatically runs `./scripts/setup.sh anyscale-workspace-ready` as the final step. If any of those prerequisites are missing, the apply still succeeds, but you need to run the post-configuration step yourself later from a Bastion-backed shell.

The guided `deploy-part1` and `deploy-part2` wrappers use these same phase-2 mechanics. The difference is that they turn the missing-token case into an intentional part-1 stop and a dead-simple part-2 continuation instead of leaving the operator to reconstruct the remaining steps by hand. `deploy-part2` is also the recommended idempotent rerun path after later phase-2 or post-config changes.

## How private AKS access works in this repository

This repository assumes local operator access is Bastion-first. The direct `az aks get-credentials` path is not enough because the downloaded kubeconfig points at the private AKS API hostname. Without Bastion, the local machine has no route to that endpoint.

If you want the shortest interactive shell path, start the preview-backed Bastion shell and fetch kubeconfig from inside it:

```bash
./scripts/setup.sh bastion
./scripts/setup.sh kubeconfig
kubectl get nodes -o wide
```

Run the second and third commands inside the Bastion-backed shell. Use `./scripts/setup.sh bastion --admin` only for break-glass admin access.

If you want the shortest local port-forwarded path from this machine, start the reusable tunnel and export the Bastion-backed kubeconfig into the current shell:

```bash
./scripts/setup.sh bastion-tunnel start
eval "$(./scripts/setup.sh kubeconfig-bastion --export)"
kubectl get nodes -o wide
```

This is the path the repo uses for local `kubectl`, `helm`, `./scripts/setup.sh anyscale-workspace-ready`, `./scripts/setup.sh anyscale-workspaces-register`, `./scripts/setup.sh validate-focused`, and `./scripts/setup.sh validate-k8s`. `./scripts/setup.sh bastion-tunnel status` tells you whether the local listener is already running, `./scripts/setup.sh bastion-tunnel stop` shuts it down, and `./scripts/setup.sh kubeconfig-bastion --admin --export` is the break-glass admin variant.

## Patch the Anyscale operator and register the CPU and GPU workspaces

If phase 2 did not auto-run the operator patch, start from a shell that already has Bastion-backed access and run the helper directly.

```bash
eval "$(./scripts/setup.sh kubeconfig-bastion --export)"
./scripts/setup.sh anyscale-workspace-ready
```

That command validates the repo-local Anyscale CLI against `ANYSCALE_HOST`, discovers the installed `anyscale-operator` Helm release and chart version, builds an AKS-specific values overlay, upgrades the live release in place, verifies that the expected CPU and GPU instance types appear in the `instance-types` ConfigMap, and checks the operator patch ConfigMap for the AKS GPU toleration changes. The generated overlay is written to `.cache/anyscale-operator.workspace-ready.values.yaml` so you can inspect exactly what the helper applied.

Once the operator patch is in place, register the dedicated CPU and GPU workspaces with a single command.

```bash
./scripts/setup.sh anyscale-workspaces-register
```

`anyscale-workspaces-register` is idempotent. It re-runs `anyscale-workspace-ready`, ensures the AKS-compatible compute configs `aks-cpu` (head `8CPU-32GB`, worker `cpu-workers` → `8CPU-32GB`, 0–1 nodes) and `aks-gpu` (head `8CPU-32GB-1xT4`, worker `gpu-workers` → `8CPU-32GB-1xT4`, 0–1 nodes) exist, then registers two workspaces against those configs. The command refreshes stale compute-config versions that still reference the earlier custom `*-AKS` instance type names and updates stopped or errored workspaces to the latest compute-config version:

- `aks-cpu-workspace` — started automatically and waited until `RUNNING`. The helper then performs a fast structural check: it looks up the Ray head pod and confirms it is scheduled on an `aks-cpu-*` node. It deliberately does **not** run an in-script Ray task, because the head pod publishes `0` schedulable Ray `CPU` resources and the `cpu-workers` group autoscales from `0`; a `num_cpus=1` Ray task therefore blocks on autoscaling that may take several minutes or stall. Run the Ray CPU probe interactively (see the manual validation section below) instead.
- `aks-gpu-workspace` — **registered only**. The helper does not start it, which keeps the GPU node pool scaled to its baseline until you actually need GPU capacity. Start it manually from the Anyscale console when you are ready to run a GPU workload.

Existing compute configs and workspaces with the same names are reused, so this command is safe to re-run. Generated compute-config YAML and command logs are written under `.cache/` (for example `.cache/anyscale-compute.aks-cpu.yaml`, `.cache/aks-cpu-workspace.validate.log`, `.cache/aks-gpu-workspace.create.log`).

If the Anyscale console **Create** flow fails on this manually registered AKS cloud with `Failed to find compute config template for AZURE`, that is not a missing `deploy-part2` step in this repository. The backend workspace-create path is healthy; the same cloud accepts `workspace_v2 create` calls against the registered `aks-cpu` and `aks-gpu` compute configs. Use the repo wrapper below as the supported workaround for creating additional workspaces:

```bash
./scripts/setup.sh anyscale-workspace-create --name my-cpu-workspace --compute-config aks-cpu
./scripts/setup.sh anyscale-workspace-create --name my-gpu-workspace --compute-config aks-gpu --start
```

The helper reuses an existing workspace name if it is already present, fails fast if the named compute config does not exist yet, and writes the create/start logs under `.cache/`.

### Run a bounded CLI runtime proof

Before the manual console proof, you can run the runtime checks from the local Bastion-backed shell. These commands are intentionally split into small steps and the wait step uses a maximum attempt count so it cannot poll forever.

```bash
eval "$(./scripts/setup.sh kubeconfig-bastion --export)"

./scripts/setup.sh anyscale-workspaces-runtime-proof start-gpu
./scripts/setup.sh anyscale-workspaces-runtime-proof wait-gpu --max-attempts 30 --interval-seconds 30
./scripts/setup.sh anyscale-workspaces-runtime-proof gpu-probe
```

`start-gpu` starts `aks-gpu-workspace` and treats an already `STARTING` or `RUNNING` workspace as success. `wait-gpu` polls `anyscale workspace_v2 status` until the workspace reaches `RUNNING`, fails fast on terminal failure states, and stops after the configured attempt budget. `gpu-probe` confirms the GPU head pod is scheduled on an `aks-gput4-*` node, runs `nvidia-smi -L`, and then runs a Ray task with `num_gpus=1` that must emit `GPU_WORKSPACE_OK`.

For convenience, `./scripts/setup.sh anyscale-workspaces-runtime-proof all` runs those three GPU steps in order. It deliberately does not run the CPU Ray probe, because the CPU workspace's head pod advertises `0` schedulable Ray CPU resources and the `cpu-workers` group autoscales from zero. If you want the bounded optional CPU check anyway, run it as a separate step:

```bash
./scripts/setup.sh anyscale-workspaces-runtime-proof cpu-probe --command-timeout-seconds 600
```

Generated logs are written under `.cache/`, including `.cache/aks-gpu-workspace.runtime.wait.log`, `.cache/aks-gpu-workspace.nvidia-smi.log`, `.cache/aks-gpu-workspace.ray-gpu.log`, and `.cache/aks-cpu-workspace.ray-cpu.log`.

If you already created `aks-gpu-workspace` before the compute config was refreshed from the custom `8CPU-32GB-1xT4-AKS` type to the built-in `8CPU-32GB-1xT4` type, the old workspace may be stuck in `ERRORED` and Anyscale will not allow updating its compute config until it reaches `TERMINATED`. In that case, create a clean replacement workspace and point the proof commands at it:

```bash
./scripts/setup.sh anyscale-workspaces-register --gpu-workspace-name aks-gpu-workspace-v2
./scripts/setup.sh anyscale-workspaces-runtime-proof start-gpu --gpu-workspace-name aks-gpu-workspace-v2
./scripts/setup.sh anyscale-workspaces-runtime-proof wait-gpu --gpu-workspace-name aks-gpu-workspace-v2 --max-attempts 30 --interval-seconds 30
./scripts/setup.sh anyscale-workspaces-runtime-proof gpu-probe --gpu-workspace-name aks-gpu-workspace-v2
```

### Manually validate the GPU workspace from the Anyscale console

After `anyscale-workspaces-register` completes, run the GPU proof by hand. This avoids the long `STARTING → RUNNING` wait on every script run and lets you exercise the console flow the way an Anyscale user would.

1. Open the Anyscale console at `https://console.azure.anyscale.com`, switch to the cloud whose name matches `ANYSCALE_CLOUD_NAME` from `.env`, and confirm that both compute configs `aks-cpu` and `aks-gpu` are listed and active.
2. Open the **Workspaces** view and confirm that `aks-cpu-workspace` is `RUNNING` and that `aks-gpu-workspace` exists in a stopped state.
3. Open `aks-cpu-workspace` and run a small Ray CPU task in a notebook or terminal, for example:

   ```python
   import ray
   ray.init(address="auto")

   @ray.remote(num_cpus=1)
   def probe():
       return "CPU_WORKSPACE_OK"

   print(ray.get(probe.remote()))
   ```

   This mirrors the automated check the script already ran and proves the CPU workspace is interactively usable.
4. Open `aks-gpu-workspace` and click **Start**. The first start can take roughly six minutes while the GPU node pool scales up from its baseline and the GPU head pod is scheduled; that is expected and is not a hang.
5. When the GPU workspace reaches `RUNNING`, open a terminal in the workspace and confirm GPU visibility:

   ```bash
   nvidia-smi -L
   ```

   You should see a single `Tesla T4` device. Then run a Ray GPU task:

   ```python
   import os
   import ray
   ray.init(address="auto")

   @ray.remote(num_gpus=1)
   def gpu_probe():
       return os.environ.get("CUDA_VISIBLE_DEVICES", "none")

   print(ray.get(gpu_probe.remote()))
   ```

   The task should return `0` (or another non-`none` device index), proving Ray scheduled a GPU-pinned task on the GPU node pool.
6. From a Bastion-backed shell, confirm the workspace head pods are scheduled on the intended AKS pools:

   ```bash
   eval "$(./scripts/setup.sh kubeconfig-bastion --export)"
   kubectl get pods -n anyscale-operator -l ray-node-type=head -o wide
   ```

   The `aks-cpu-workspace` head pod's node name should start with `aks-cpu-`, and once the GPU workspace is running its head pod's node name should start with `aks-gput4-`.

When you are done, you can stop `aks-gpu-workspace` from the Anyscale console so the GPU node pool scales back down. `aks-cpu-workspace` is safe to leave running as the always-on CPU entrypoint.

## Validate the codebase and the deployed environment

There are two kinds of validation in this repository. The first kind is the code and plan validation you should run before or during deployment. The second kind is the live cluster and platform validation you should run after phase 2 and the post-configuration steps have completed.

For code and plan validation, `./scripts/setup.sh validate` is the standard wrapper path and `./scripts/validate-static.sh` is the non-deploying helper that writes a summary under `.cache/static-validation/<timestamp>/`. The dedicated apply test at `infra/terraform/tests/apply.tftest.hcl` is intentionally limited to the Azure phase-1 shape: it provisions the phase-1 resources, asserts the outputs and private-mode invariants, and destroys them automatically when the test ends.

```bash
./scripts/setup.sh validate
./scripts/validate-static.sh

cd infra/terraform
terraform test -filter=tests/apply.tftest.hcl -verbose
```

After phase 2 and the Anyscale post-configuration steps are in place, run the live validation sequence from a shell that already has Bastion-backed access.

```bash
./scripts/setup.sh validate-focused
./scripts/setup.sh validate-k8s
./scripts/setup.sh validate-observability
./scripts/setup.sh control-plane-egress-smoke
```

`validate-focused` is the fastest rerunnable proof set and writes per-check logs plus a summary under `.cache/focused-validation/<timestamp>/`. It verifies `kubectl` access, namespace preparation, private DNS and egress behavior, Workload Identity storage access, internal ingress reachability, GPU scheduling, and optionally observability. `validate-k8s` expands the Kubernetes checks, `functional-test` remains as a shorthand wrapper around that same Kubernetes validation path, `validate-observability` queries Log Analytics after ingestion catches up, and `control-plane-egress-smoke` confirms that in-cluster workloads can resolve and reach the Anyscale control-plane endpoints plus any additional FQDNs configured in `TF_VAR_anyscale_fqdns`.

`./scripts/test-timeouts.sh` is also available when you want to validate the timeout wrapper itself without waiting on Azure, Bastion, or Terraform.

## Success criteria for a bring-your-own AKS integration

This repository provisions its own AKS cluster today, but the same integration pattern can be used as the acceptance bar for a bring-your-own AKS variant. If you want to bring an existing AKS cluster with one CPU node pool and one GPU node pool into this Anyscale flow, the integration should only be considered successful when all of the following are true:

- The target AKS cluster is reachable through the Bastion-backed access path and, in addition to whatever system pool AKS itself requires, exposes one schedulable CPU node pool and one schedulable GPU node pool with the expected selectors, taints, and NVIDIA device availability.
- The phase-2 ARM and Terraform flow completes without manual portal repair work, and the Azure-native Anyscale cloud resource plus the `anyscaleoperator` AKS extension both reach `Succeeded`.
- `./scripts/setup.sh anyscale-workspace-ready` succeeds, the live operator release accepts the token patch, and the resulting `instance-types` ConfigMap contains at least one CPU-only instance type and one GPU-backed instance type that map cleanly to the CPU and GPU pools.
- `./scripts/setup.sh validate-focused`, `./scripts/setup.sh validate-k8s`, and `./scripts/setup.sh control-plane-egress-smoke` all pass, proving private API access, firewall-routed egress, Workload Identity storage access, internal ingress reachability, and GPU scheduling.
- `./scripts/setup.sh anyscale-workspaces-register` succeeds: it registers the `aks-cpu` and `aks-gpu` compute configs, registers `aks-cpu-workspace` and `aks-gpu-workspace`, starts the CPU workspace, waits until it reaches `RUNNING`, and confirms the CPU head pod is scheduled on the `aks-cpu` node pool.
- A console session against `aks-cpu-workspace` runs a small Ray CPU task on the CPU pool using the CPU-only instance type.
- After starting `aks-gpu-workspace` from the bounded CLI proof or the Anyscale console, a console session runs a small Ray GPU task on the GPU pool, with `nvidia-smi -L` reporting a `Tesla T4` and the Ray task returning a valid `CUDA_VISIBLE_DEVICES` value.
- The end-to-end path is repeatable: re-running `./scripts/setup.sh anyscale-workspaces-register` reuses the existing compute configs and workspaces without recreating them, and the manual GPU validation can be repeated through the console without reworking the underlying AKS, Bastion, identity, or operator wiring by hand.

## Inspect the environment during and after deployment

`./scripts/setup.sh outputs` prints the Terraform outputs. `./scripts/setup.sh status` gives you the read-only operator view of the environment: Terraform resource names, Anyscale cloud metadata, Azure AKS state, node pool state, enterprise DNS path, and, when the current shell already has Bastion-backed Kubernetes access, the live node list, Helm add-ons, and ingress service details. `./scripts/setup.sh post` is a shorter reminder of the Bastion-backed bootstrap and post-configuration workflow if you need a quick refresher from the command line.

## Tear the environment down

Use `destroy` when you want Terraform to delete the deployed resources in the normal way.

```bash
./scripts/setup.sh destroy
```

The command asks you to type the project name from `.env` before it proceeds, stops any running Bastion tunnel, runs `terraform destroy`, and clears the cached Anyscale cloud deployment ID from `.env`.

Use `nuke` when you need a full reset after a failed private-cluster experiment and want Azure CLI to delete the resource group directly before removing local Terraform state and saved plan files.

```bash
./scripts/setup.sh nuke
./scripts/setup.sh nuke --yes
```

`nuke` is intentionally stronger than `destroy`. It waits for the resource group deletion to finish, removes local Terraform state and plan files, keeps `.env` and `.terraform.lock.hcl`, and leaves you ready to run `./scripts/setup.sh init` before the next plan or apply.

## Current validated baseline

The most recent end-to-end rerun completed on `2026-05-12` against Kubernetes `1.34.6` in `westus3`. That run completed the two-phase deployment, left the AKS cluster private and healthy, applied the Terraform-managed bootstrap layer, deployed the Anyscale platform resources, patched the operator successfully, and registered the AKS-aligned `aks-cpu` and `aks-gpu` compute configs plus the `aks-cpu-workspace` and `aks-gpu-workspace` workspaces used by the manual CPU and GPU validation path.

The two current non-blocking caveats are worth knowing before you rely on the environment as a long-lived reference. The operator pod still emits recurring `502 Bad Gateway` warnings from the `vector` sidecar telemetry sinks on `http://localhost:3100` and `http://localhost:3101/api/v1/push`, and the custom GPU instance type still needs the legacy resource key `'accelerator_type:T4': 1` alongside `accelerators: [T4]` for the live admission webhook. Neither issue blocked the validated workflow, but both are worth keeping in mind when you compare this repository to newer upstream operator behavior.

## Supporting notes

`docs/current-state.md` keeps the longer engineering notes behind the validated deployment sequence. `VALIDATION.md` remains as a compatibility pointer to this README. `ANYSCALE-DOCS-FEEDBACK.md` records the public-docs gaps that surfaced while validating this private AKS workflow.
