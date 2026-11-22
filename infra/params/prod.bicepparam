using '../main.bicep'

param location = 'westeurope'
param env = 'prod'
param tags = {
  environment: 'prod'
  owner: 'platform-team'
  costCenter: 'platform'
}

param hubAddressPrefix = '10.110.0.0/24'
param spokeAddressPrefix = '10.120.0.0/21'

// Egress through the hub firewall; the IP is supplied at deploy time.
param firewallPrivateIp = readEnvironmentVariable('HUB_FIREWALL_IP', '')

param kubernetesVersion = '1.31'
param nodePools = [
  {
    name: 'system'
    vmSize: 'Standard_D4ds_v5'
    minCount: 3
    maxCount: 5
    zones: ['1', '2', '3']
  }
  {
    name: 'apps'
    vmSize: 'Standard_D8ds_v5'
    minCount: 3
    maxCount: 20
    zones: ['1', '2', '3']
  }
]

param adminGroupObjectIds = filter(split(readEnvironmentVariable('AKS_ADMIN_GROUP_ID', ''), ','), v => !empty(v))

param alertEmails = filter(split(readEnvironmentVariable('ALERT_EMAIL', ''), ','), v => !empty(v))

// Cost guardrail for the platform resource group (billing currency).
param monthlyBudget = 4000
param budgetStartDate = '2026-12-01'
