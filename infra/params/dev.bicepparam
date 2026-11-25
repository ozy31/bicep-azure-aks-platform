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
  // GPU inference pool: empty until a pod that tolerates the taint is pending.
  {
    name: 'gpu'
    vmSize: 'Standard_NC4as_T4_v3'
    minCount: 0
    maxCount: 2
    zones: []
    taints: ['nvidia.com/gpu=present:NoSchedule']
    labels: {
      workload: 'inference'
    }
    priority: 'Spot'
  }
]

// Comma-separated object IDs come from the environment so none are committed.
param adminGroupObjectIds = filter(split(readEnvironmentVariable('AKS_ADMIN_GROUP_ID', ''), ','), v => !empty(v))

param workloadIdentities = [
  {
    namespace: 'demo'
    serviceAccountName: 'demo-app'
  }
  {
    namespace: 'inference'
    serviceAccountName: 'llm-gateway'
    openAi: true
  }
]

// Cost guardrail for the platform resource group (billing currency).
param monthlyBudget = 500
param budgetStartDate = '2026-12-01'

// Data zone deployments keep prompts and completions inside the EU.
param openAiDeployments = [
  {
    name: 'gpt-4o-mini'
    model: 'gpt-4o-mini'
    version: '2024-07-18'
    sku: 'DataZoneStandard'
    capacity: 10
  }
]
