# 0003: Unattended upgrades, and features that only prod pays for

## Status

Accepted

## Context

A private cluster that nobody patches by hand falls behind within weeks.
Turning on auto-upgrade alone is not enough: an upgrade that starts at
11:00 on a Tuesday, or drains a node whose PodDisruptionBudget never allows
an eviction, causes the outage it was meant to prevent.

Some AKS features are billed per node or per vCore, or need the Standard
tier. Running them in dev doubles the cost of an environment that exists
to be thrown away.

## Decision

Upgrades:

- `upgradeChannel: patch` and `nodeOSUpgradeChannel: NodeImage`. Minor
  versions stay a reviewed change to `kubernetesVersion`.
- Both channels run only inside weekly maintenance windows. The node image
  window starts when the control plane window ends, computed from it, so the
  two can never overlap after someone edits one of them.
- Every pool surges 33%, waits up to 30 minutes for a node to drain, and
  soaks each batch for 5 minutes. A blocked drain fails the upgrade and
  shows up in the activity log instead of hanging.

Prod only, switched on `env == 'prod'`:

| Feature | Why not in dev |
| --- | --- |
| Standard tier (API server SLA) | Dev can tolerate the Free tier's best effort. |
| Defender for Containers | Billed per vCore; dev runs no customer data. |
| Cost analysis add-on | Requires the Standard tier. |
| `kube-apiserver` logs | The highest-volume category; audit-admin is kept everywhere. |
| Key Vault purge protection | Cannot be turned off, which would make dev undeletable. |

## Consequences

- Patches land within a week without anyone scheduling them.
- A workload with `maxUnavailable: 0` and one replica blocks node upgrades.
  This is surfaced, not hidden; fix the PDB.
- The tests pin each prod-only switch to the same condition, so the tier
  and the cost analysis add-on cannot drift apart.
- Dev does not exercise Defender. Alerts from it are tested in prod's
  staging subscription, not here.
