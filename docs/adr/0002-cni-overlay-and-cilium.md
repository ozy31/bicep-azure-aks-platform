# 2. Azure CNI Overlay with the Cilium dataplane

## Status

Accepted

## Context

Classic Azure CNI gives every pod a vnet IP, which forces large subnets and
exhausts address space shared with the hub. Kubenet is being retired.

## Decision

Use Azure CNI in overlay mode with the Cilium dataplane and Cilium network
policy. Nodes take IPs from a /22 node subnet; pods use a private
`10.244.0.0/16` range that never appears in the vnet.

## Consequences

- The spoke fits in a /21, and the pod CIDR can be reused across clusters.
- Pods are not directly routable from the hub. Traffic into the cluster goes
  through internal load balancers or ingress, which is what we want anyway.
- eBPF-based policy and Hubble flow logs are available without a separate CNI.
- Windows node pools are not supported with the Cilium dataplane.
