# bicep-azure-aks-platform

A private AKS platform on Azure, written in Bicep and deployed as a
subscription-scope **deployment stack**.

My Terraform versions of this platform live in
[terraform-azure-aks-platform](https://github.com/ozy31/terraform-azure-aks-platform)
and [terraform-azure-landing-zone](https://github.com/ozy31/terraform-azure-landing-zone).
This repo builds the same kind of platform with Azure-native tooling, using the
Bicep features that matter in practice: user-defined types, exported
functions, `.bicepparam` files, and deployment stacks with deny settings.

## What it deploys

```
subscription
├── rg-aks-hub-<env>-<region>
│   ├── vnet (AzureFirewallSubnet, snet-shared)
│   └── private DNS zones: vaultcore, azurecr  ── linked to hub + spoke
└── rg-aks-<env>-<region>
    ├── spoke vnet (snet-aks-nodes /22, snet-private-endpoints /24)
    │   ├── NSG, optional UDR 0.0.0.0/0 → hub firewall
    │   └── peered with the hub in both directions
    ├── AKS (private API server, Entra ID only, Azure RBAC)
    │   ├── Azure CNI Overlay + Cilium dataplane and network policy
    │   ├── workload identity + OIDC issuer
    │   ├── system pool (tainted CriticalAddonsOnly) + user pools
    │   └── Key Vault CSI driver, Azure Policy, image cleaner
    ├── Key Vault (RBAC, public access off, private endpoint)
    ├── ACR Premium (admin user off, public access off, private endpoint)
    ├── Log Analytics (shared keys off) + diagnostics on every resource
    └── Azure Monitor workspace (managed Prometheus) + alert rules
```

## Security decisions

| Decision | Where | Why |
| --- | --- | --- |
| `disableLocalAccounts: true` | `modules/aks/cluster.bicep` | No static kubeconfig exists; every request is an Entra ID identity in the audit log. |
| Private API server, no public FQDN | same | The control plane is reachable only from the peered networks. |
| Workload identity, no secrets | `modules/identity/workload-identity.bicep` | Pods exchange a projected service account token for an Entra ID token. |
| Key Vault and ACR with public access disabled | `modules/security`, `modules/registry` | Reached through private endpoints that register their own DNS records. |
| User-assigned control plane and kubelet identities | `modules/aks/cluster.bicep` | Role assignments are created before the cluster, so the first deploy does not race RBAC propagation. |
| `denyDelete` on the stack | `scripts/deploy.sh` | Resources managed from Git cannot be deleted by hand in the portal. |

These are enforced by tests, not only documented: `tests/test_template.py`
compiles the template and fails if any of them is turned off.

## Usage

Requirements: Azure CLI 2.61+ (deployment stacks), `az bicep install`, Python 3.

```bash
make lint      # Bicep linter, warnings are errors (see bicepconfig.json)
make params    # compile dev and prod .bicepparam files
make test      # build out/main.json and run the security baseline tests
```

Against a subscription:

```bash
az login
export AKS_ADMIN_GROUP_ID=<entra-group-object-id>   # comma-separated for several
make what-if ENV=dev
make apply ENV=dev
scripts/kubeconfig.sh dev    # from inside the network; the API server is private
```

`prod` refuses to apply without `CONFIRM_PROD=yes` and reads the hub
firewall IP from `HUB_FIREWALL_IP` to switch egress to user-defined routing.
No object IDs, subscription IDs or emails are committed: everything
tenant-specific comes from environment variables.

## CI

`.github/workflows/ci.yml` runs lint, parameter compilation, the baseline
tests and shellcheck on every push. On pull requests it also runs `what-if`
for dev and prod through OIDC federation (no client secret) and posts the
diff to the job summary. That job is skipped until the repository variables
`AZURE_CLIENT_ID`, `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID` are set.

## Layout

```
infra/main.bicep            subscription-scope composition
infra/params/*.bicepparam   per-environment values
modules/shared/types.bicep  exported types, naming functions, region codes
modules/network             vnet, hub, spoke, hub-attach, private endpoint
modules/aks                 cluster, identities, node pools, diagnostics
modules/security            Key Vault
modules/registry            ACR
modules/identity            AcrPull, federated workload identities
modules/monitoring          Log Analytics, managed Prometheus, alerts
docs/adr                    design decisions
```

## Status

Validated by the Bicep compiler, the linter at error level and the baseline
tests. I have not run it against a live subscription from this repo; `what-if`
in CI is the next step once a sandbox subscription is wired in.

## License

MIT
