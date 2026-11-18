#!/usr/bin/env bash
# Fetches Entra ID credentials for the private cluster and converts them for
# kubelogin. The API server has no public endpoint, so run this from inside
# the hub/spoke network (VPN, Bastion jump box or a self-hosted runner), or
# use `az aks command invoke` from anywhere.
set -euo pipefail

env="${1:?usage: kubeconfig.sh <dev|prod>}"
outputs="$(az stack sub show --name "stack-aks-platform-$env" --query outputs -o json)"
rg="$(jq -r '.platformResourceGroup.value' <<<"$outputs")"
cluster="$(jq -r '.clusterName.value' <<<"$outputs")"

az aks get-credentials --resource-group "$rg" --name "$cluster" --overwrite-existing
kubelogin convert-kubeconfig -l azurecli
echo "context: $(kubectl config current-context)"
