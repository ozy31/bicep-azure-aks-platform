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
param actionGroupId string

@description('Throttled (HTTP 429) requests per 15 minutes before the quota alert fires.')
param throttleAlertThreshold int = 50

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

// Sustained 429s mean the deployment needs more tokens-per-minute capacity
// (or a second region), not that callers should retry harder.
resource throttleAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-${name}-throttled'
  location: 'global'
  tags: tags
  properties: {
    description: 'Azure OpenAI is rejecting requests with 429: a deployment is out of quota.'
    severity: 2
    enabled: true
    scopes: [account.id]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'throttled'
          metricNamespace: 'Microsoft.CognitiveServices/accounts'
          metricName: 'AzureOpenAIRequests'
          dimensions: [
            { name: 'StatusCode', operator: 'Include', values: ['429'] }
            { name: 'ModelDeploymentName', operator: 'Include', values: ['*'] }
          ]
          operator: 'GreaterThan'
          threshold: throttleAlertThreshold
          timeAggregation: 'Total'
        }
      ]
    }
    actions: [
      { actionGroupId: actionGroupId }
    ]
  }
}

output id string = account.id
output name string = account.name
output endpoint string = account.properties.endpoint
