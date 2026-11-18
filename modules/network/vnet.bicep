// A virtual network with typed subnets and diagnostics to Log Analytics.

import { requiredTags, subnet } from '../shared/types.bicep'

param location string
param tags requiredTags
param name string
param addressPrefixes string[]
param subnets subnet[]
param logAnalyticsId string

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: addressPrefixes
    }
    subnets: [
      for s in subnets: {
        name: s.name
        properties: {
          addressPrefix: s.addressPrefix
          networkSecurityGroup: s.?networkSecurityGroupId == null ? null : { id: s.networkSecurityGroupId! }
          routeTable: s.?routeTableId == null ? null : { id: s.routeTableId! }
          privateEndpointNetworkPolicies: s.?privateEndpointNetworkPolicies ?? 'Enabled'
          delegations: s.?delegation == null
            ? []
            : [
                {
                  name: 'delegation'
                  properties: { serviceName: s.delegation! }
                }
              ]
        }
      }
    ]
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: vnet
  properties: {
    workspaceId: logAnalyticsId
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output id string = vnet.id
output name string = vnet.name
output subnetIds object = toObject(vnet.properties.subnets, s => s.name, s => s.id)
