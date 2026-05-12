# Current State Notes

`README.md` is the canonical setup and operator guide for this repository. This file keeps a short engineering summary of what the sample is designed to prove and what still deserves operator attention after a successful deployment.

## What the sample is intended to validate

- The Azure side of the deployment can create the private network, private AKS cluster, Bastion access path, storage, registry, routing, identity, and observability resources from Terraform.
- The deployment is meant to run in two phases: infrastructure first, then a Bastion-backed rerun that gives Terraform live Kubernetes access for the bootstrap layer and Azure-native Anyscale platform resources.
- The Terraform-managed bootstrap layer is expected to prepare the namespaces, service-account adoption metadata, workload identity wiring, ingress-nginx, and the NVIDIA device plugin before the extension-driven operator path is exercised.
- The cluster is intended to host the operator and workloads only; the Anyscale console remains SaaS-hosted and is reached through the documented control-plane endpoints.

## Operational assumptions that matter

- Treat local access to the private cluster as Bastion-first for kubectl, Helm, validation helpers, and post-deploy Anyscale tasks.
- Keep the CPU pool schedulable for operator components and supporting system workloads.
- Keep GPU pools tainted and rely on explicit selectors and tolerations for GPU workloads.
- Allow the documented Microsoft, marketplace, container registry, NVIDIA, and Anyscale egress endpoints through Azure Firewall so cluster bootstrap and notebook workloads can succeed.

## Supporting notes

- The architecture diagram and README reflect the current intended state of the sample, including the Azure-native Anyscale platform deployment path and Log Analytics plus AMPLS observability.
- If you capture local validation transcripts while iterating, keep them under `.cache/` so they remain local-only artifacts instead of repository content.
