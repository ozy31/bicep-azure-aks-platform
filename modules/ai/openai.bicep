// Azure OpenAI reachable only through a private endpoint, with API keys
// disabled: callers authenticate with Entra ID (workload identity from AKS).

import { environment, requiredTags } from '../shared/types.bicep'

param location string
param env environment
param tags requiredTags
param name string
param privateEndpointSubnetId string
param privateDnsZoneId string
param logAnalyticsId string

@description('Model deployments. Capacity is in thousands of tokens per minute.')
param deployments {
  name: string
  model: string
  version: string
  sku: ('Standard' | 'GlobalStandard' | 'DataZoneStandard')
  capacity: int
}[] = []

resource account 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: name
  location: location
  tags: tags
  kind: 'OpenAI'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    // Required for Entra ID authentication and private endpoints.
    customSubDomainName: name
    publicNetworkAccess: 'Disabled'
    disableLocalAuth: true
    networkAcls: {
      defaultAction: 'Deny'
    }
    // The account cannot call out to arbitrary URLs (e.g. "bring your own data" sources).
    restrictOutboundNetworkAccess: true
    allowedFqdnList: []
  }
}

// The service rejects concurrent deployment changes on one account.
@batchSize(1)
resource modelDeployments 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = [
  for d in deployments: {
    parent: account
    name: d.name
    sku: {
      name: d.sku
      capacity: d.capacity
    }
    properties: {
      model: {
        format: 'OpenAI'
        name: d.model
        version: d.version
      }
      // Pinned versions; upgrades go through a pull request, not a retirement date.
      versionUpgradeOption: 'NoAutoUpgrade'
    }
  }
]

module endpoint '../network/private-endpoint.bicep' = {
  name: 'pe-${name}'
  params: {
    location: location
    tags: tags
    name: 'pe-${name}'
    subnetId: privateEndpointSubnetId
    targetResourceId: account.id
    groupId: 'account'
    privateDnsZoneId: privateDnsZoneId
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: account
  properties: {
    workspaceId: logAnalyticsId
    logs: [
      { categoryGroup: 'audit', enabled: true }
      // Request logs carry no prompts, but they are high volume; prod only.
      { category: 'RequestResponse', enabled: env == 'prod' }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

output id string = account.id
output name string = account.name
output endpoint string = account.properties.endpoint
