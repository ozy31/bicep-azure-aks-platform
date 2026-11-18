// Premium Azure Container Registry: private endpoint only, admin user off,
// zone redundant in prod. Pulls are granted to the kubelet identity elsewhere.

import { environment, requiredTags } from '../shared/types.bicep'

param location string
param env environment
param tags requiredTags
param name string
param privateEndpointSubnetId string
param privateDnsZoneId string
param logAnalyticsId string

@description('Days to keep untagged manifests before they are purged.')
param untaggedRetentionDays int = 7

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    // Private endpoints require Premium.
    name: 'Premium'
  }
  properties: {
    adminUserEnabled: false
    publicNetworkAccess: 'Disabled'
    networkRuleBypassOptions: 'None'
    zoneRedundancy: env == 'prod' ? 'Enabled' : 'Disabled'
    dataEndpointEnabled: false
    policies: {
      retentionPolicy: {
        status: 'enabled'
        days: untaggedRetentionDays
      }
      exportPolicy: {
        status: 'disabled'
      }
    }
  }
}

module endpoint '../network/private-endpoint.bicep' = {
  name: 'pe-${name}'
  params: {
    location: location
    tags: tags
    name: 'pe-${name}'
    subnetId: privateEndpointSubnetId
    targetResourceId: registry.id
    groupId: 'registry'
    privateDnsZoneId: privateDnsZoneId
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: registry
  properties: {
    workspaceId: logAnalyticsId
    logs: [
      {
        categoryGroup: 'audit'
        enabled: true
      }
    ]
  }
}

output id string = registry.id
output name string = registry.name
output loginServer string = registry.properties.loginServer
