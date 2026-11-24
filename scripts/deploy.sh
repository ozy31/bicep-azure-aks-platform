#!/usr/bin/env bash
# Deploys infra/main.bicep as a subscription-scope deployment stack.
#
#   scripts/deploy.sh <dev|prod> what-if   # preview changes
#   scripts/deploy.sh <dev|prod> apply     # create or update the stack
#   scripts/deploy.sh <dev|prod> destroy   # delete the stack and its resources
#
# The stack denies delete on managed resources (denySettingsMode
# denyDelete), so nobody removes a piece of the platform by hand. Removing a
# resource from the template deletes it on the next apply (--action-on-unmanage
# deleteAll), which keeps the subscription in sync with Git.
set -euo pipefail

usage="usage: deploy.sh <dev|prod> <what-if|apply|destroy>"
env="${1:?$usage}"
action="${2:?$usage}"
root="$(cd "$(dirname "$0")/.." && pwd)"
params="$root/infra/params/$env.bicepparam"
stack="stack-aks-platform-$env"
location="${LOCATION:-westeurope}"

[[ -f "$params" ]] || { echo "no parameter file for '$env'" >&2; exit 1; }

echo "subscription: $(az account show --query '[name, id]' -o tsv | paste -sd' ' -)"
if [[ "$env" == "prod" && "$action" != "what-if" && "${CONFIRM_PROD:-}" != "yes" ]]; then
  echo "refusing to $action prod without CONFIRM_PROD=yes" >&2
  exit 1
fi

# The identity running the deployment stays exempt from the deny assignment,
# otherwise the next apply could not replace resources the stack manages.
deployer_id() {
  az ad signed-in-user show --query id -o tsv 2>/dev/null \
    || az ad sp show --id "$(az account show --query user.name -o tsv)" --query id -o tsv
}

# BREAK_GLASS_PRINCIPAL_IDS (comma-separated object IDs) are also exempt, so
# an emergency account can remove a broken resource when the pipeline is
# down. Keep the list to one or two monitored accounts. At most five
# principals can be excluded, the deployer included.
excluded_principals() {
  local ids=("$1") id
  local guid='^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
  IFS=',' read -ra extra <<<"${BREAK_GLASS_PRINCIPAL_IDS:-}"
  for id in "${extra[@]}"; do
    id="${id// /}"
    [[ -z "$id" ]] && continue
    [[ "$id" =~ $guid ]] || { echo "BREAK_GLASS_PRINCIPAL_IDS: '$id' is not an object ID" >&2; return 1; }
    ids+=("$id")
  done
  (( ${#ids[@]} <= 5 )) || { echo "at most 5 principals can be excluded from deny settings" >&2; return 1; }
  echo "${ids[*]}"
}

case "$action" in
  what-if)
    az deployment sub what-if \
      --name "whatif-$env-$(date +%s)" \
      --location "$location" \
      --parameters "$params"
    ;;
  apply)
    excluded="$(excluded_principals "$(deployer_id)")"
    # shellcheck disable=SC2086 # one argument per principal ID
    az stack sub create \
      --name "$stack" \
      --location "$location" \
      --parameters "$params" \
      --action-on-unmanage deleteAll \
      --deny-settings-mode denyDelete \
      --deny-settings-apply-to-child-scopes \
      --deny-settings-excluded-principals $excluded \
      --description "AKS platform ($env), managed from Git" \
      --yes
    ;;
  destroy)
    az stack sub delete --name "$stack" --action-on-unmanage deleteAll --yes
    ;;
  *)
    echo "$usage" >&2
    exit 1
    ;;
esac
