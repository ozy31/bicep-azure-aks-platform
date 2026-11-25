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
    │   ├── GPU inference pool, scales from zero (Spot in dev)
    │   ├── KEDA and VPA add-ons
    │   ├── Key Vault CSI driver, Azure Policy, image cleaner
    │   └── prod: Defender for Containers, cost analysis, Standard tier
    ├── Key Vault (RBAC, public access off, private endpoint)
    ├── ACR Premium (admin user off, public access off, private endpoint)
    ├── Azure OpenAI (optional: keys off, public access off, private endpoint, pinned models)
    ├── Log Analytics (shared keys off) + diagnostics on every resource
    ├── Azure Monitor workspace (managed Prometheus) + alert rules
    ├── Service Health alert: Azure incidents for AKS, Key Vault, ACR, network in this region
    └── monthly cost budget: 80% actual and 100% forecast alerts
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
| Upgrades only in maintenance windows | `modules/aks/cluster.bicep` | Patch releases and node images roll on Sunday nights, node images after the control plane, never in business hours. |
| Drain timeout and soak time per upgrade batch | same | A blocked drain fails fast, and a bad node image is visible before the next batch rolls. |
| Defender for Containers in prod | same | Runtime threat detection where the real workloads run, without paying for it in dev. |
| Break-glass principals exempt from deny settings | `scripts/deploy.sh` | `BREAK_GLASS_PRINCIPAL_IDS` lets an emergency account fix a broken resource when the pipeline is down; everyone else stays denied. |
| Azure OpenAI without API keys | `modules/ai/openai.bicep` | `disableLocalAuth` plus a private endpoint: pods call models with workload identity, and only identities marked `openAi: true` get the OpenAI User role. |
| Pinned model versions | same | A model version changes in a pull request, not on Microsoft's retirement schedule. |
| GPU pool tainted and scaling from zero | `infra/params/*.bicepparam` | GPU nodes exist only while a pod that asked for one is pending. |
| Cost budget per environment | `modules/cost/budget.bicep` | The forecast alert flags a month that is heading over budget while there is still time to act. |

These are enforced by tests, not only documented: `tests/test_template.py`
compiles the template and fails if any of them is turned off.

## Usage

Requirements: Azure CLI 2.61+ (deployment stacks), `az bicep install`, Python 3.

```bash
make fmt-check # every file matches `az bicep format`
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

Azure OpenAI is created only when `openAiDeployments` is set (dev deploys
`gpt-4o-mini`). The `openAiEndpoint` output and a workload identity's client
ID are all a pod needs; there is no key to distribute.

`BREAK_GLASS_PRINCIPAL_IDS` (comma-separated object IDs, optional) adds
emergency accounts to the deny-settings exclusions next to the deployer.

`prod` refuses to apply without `CONFIRM_PROD=yes` and reads the hub
firewall IP from `HUB_FIREWALL_IP` to switch egress to user-defined routing.
No object IDs, subscription IDs or emails are committed: everything
tenant-specific comes from environment variables.

## Alerts

Everything routes to one action group per environment:

| Source | Alerts |
| --- | --- |
| Managed Prometheus | crash looping pods, NotReady nodes, node filesystem and PVCs filling up, deployments short of replicas, failed Jobs |
| Service Health | Azure incidents, required actions, maintenance and security advisories for the platform's services in its region |
| Azure OpenAI | sustained HTTP 429 (a deployment is out of tokens-per-minute quota) |
| Cost Management | 80% of the monthly budget spent, 100% forecast |

The tests check that every Prometheus rule has a hold time, a severity, an
action group and auto-resolve, and parse each expression with `promtool`
so a typo fails CI instead of the deployment.

## CI

`.github/workflows/ci.yml` runs the format check, lint, parameter compilation, the baseline
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
modules/ai                  Azure OpenAI account, model deployments, quota alert
modules/identity            AcrPull, federated workload identities
modules/monitoring          Log Analytics, managed Prometheus, alerts
modules/cost                monthly budget with actual and forecast alerts
docs/adr                    design decisions (stacks, networking, upgrades, AI workloads)
```

## Status

Validated by the Bicep compiler, the linter at error level and the baseline
tests. I have not run it against a live subscription from this repo; `what-if`
in CI is the next step once a sandbox subscription is wired in.

## License

MIT
