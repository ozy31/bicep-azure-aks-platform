# 1. Bicep with deployment stacks instead of Terraform state

## Status

Accepted

## Context

The Terraform versions of this platform keep state in a storage account,
need a locking strategy, and drift silently when someone changes a resource
in the portal. For a team that only targets Azure, the platform itself can
hold the state.

## Decision

Write the platform in Bicep and deploy it as a subscription-scope deployment
stack:

- `--action-on-unmanage deleteAll`: a resource removed from the template is
  deleted on the next apply, the same as removing it from Terraform.
- `--deny-settings-mode denyDelete`: Azure blocks deletes of managed
  resources by anyone except the deploying identity.
- `what-if` gives the plan step in pull requests.

## Consequences

- No state file, no backend to secure, no lock table.
- New Azure features are available on day one through the resource provider
  API version, without waiting for a provider release.
- Azure only. Cloudflare, GitHub or Datadog resources still need Terraform.
- `what-if` is noisier than `terraform plan` on some resource types, so
  reviewers should read it as a guide, not a guarantee.
