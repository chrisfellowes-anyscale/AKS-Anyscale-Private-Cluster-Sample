# Agent Skills Used

This repository does not track local agent skill bundles. Local copies under `.agents/skills/` and `.claude/` are machine-local assistant context.

## HashiCorp Terraform Skills

Source: `hashicorp/agent-skills`.

Used in this refactor for Terraform style guidance, module boundary review, AVM comparison, and Terraform test planning. The provider implementation skills were inspected but were not relevant because this repository is Terraform configuration and workflow code, not a Terraform provider.

Relevant skills:

- `azure-verified-modules`
- `refactor-module`
- `terraform-style-guide`
- `terraform-test`

Inspected but not used for implementation:

- `new-terraform-provider`
- `provider-actions`
- `provider-docs`
- `provider-resources`
- `provider-test-patterns`
- `run-acceptance-tests`
- `terraform-search-import`
- `terraform-stacks`

## Anyscale Repository Skills

Source: local Anyscale skill files under `.claude/skills/`.

Used in this refactor for Anyscale-on-Kubernetes infrastructure guidance, live workload execution planning, diagnostics planning, and Ray workload proof design.

Relevant skills:

- `anyscale-infra-kubernetes`
- `anyscale-platform-ask`
- `anyscale-platform-inspect`
- `anyscale-platform-run`
- `anyscale-platform-fix`
- `anyscale-workload-ray-data`
- `anyscale-workload-ray-serve`

Inspected but not used for implementation:

- `anyscale-infra-aws-vm`
- `anyscale-infra-gcp-vm`
- `anyscale-workload-batch-embedding`
- `anyscale-workload-llm-post-training`
- `anyscale-workload-llm-serving`
- `anyscale-workload-ray-train`

## Source-Control Policy

Do not commit local skill bundle directories or generated lock files. Keep this note as the tracked record of which assistant skills informed repository work and why.
