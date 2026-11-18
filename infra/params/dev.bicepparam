using '../main.bicep'

param location = 'westeurope'
param env = 'dev'
param tags = {
  environment: 'dev'
  owner: 'platform-team'
  costCenter: 'platform'
}

param hubAddressPrefix = '10.10.0.0/24'
param spokeAddressPrefix = '10.20.0.0/21'

param kubernetesVersion = '1.31'
param nodePools = [
  {
    name: 'system'
    vmSize: 'Standard_D2ds_v5'
    minCount: 1
    maxCount: 3
    zones: []
  }
  {
    name: 'apps'
    vmSize: 'Standard_D4ds_v5'
    minCount: 1
    maxCount: 5
    zones: []
  }
]

// Comma-separated object IDs come from the environment so none are committed.
param adminGroupObjectIds = filter(split(readEnvironmentVariable('AKS_ADMIN_GROUP_ID', ''), ','), v => !empty(v))

param workloadIdentities = [
  {
    namespace: 'demo'
    serviceAccountName: 'demo-app'
  }
]
