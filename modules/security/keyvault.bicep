// Key Vault with RBAC authorization, no public network access and a
// private endpoint. Purge protection is on in prod and cannot be undone.

import { environment, requiredTags } from '../shared/types.bicep'

param location string
param env environment
param tags requiredTags
param name string
param privateEndpointSubnetId string
param privateDnsZoneId string
param logAnalyticsId string

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    tenantId: tenant().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: env == 'prod' ? 90 : 7
    // Only `true` is accepted once set, so dev leaves it unset to stay deletable.
    enablePurgeProtection: env == 'prod' ? true : null
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'None'
      defaultAction: 'Deny'
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
    targetResourceId: vault.id
    groupId: 'vault'
    privateDnsZoneId: privateDnsZoneId
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: vault
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

output id string = vault.id
output name string = vault.name
output uri string = vault.properties.vaultUri
