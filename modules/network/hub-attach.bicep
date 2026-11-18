// Runs in the hub resource group: peers the hub back to a spoke and links
// the spoke to the shared private DNS zones.

import { requiredTags } from '../shared/types.bicep'

param hubVnetName string
param spokeVnetId string
param spokeVnetName string
param privateDnsZoneNames string[]
param tags requiredTags

resource hubVnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: hubVnetName
}

resource hubToSpoke 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: hubVnet
  name: 'peer-to-${spokeVnetName}'
  properties: {
    remoteVirtualNetwork: {
      id: spokeVnetId
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
  }
}

resource zones 'Microsoft.Network/privateDnsZones@2024-06-01' existing = [
  for zone in privateDnsZoneNames: {
    name: zone
  }
]

resource links 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for (zone, i) in privateDnsZoneNames: {
    parent: zones[i]
    name: 'link-${spokeVnetName}'
    location: 'global'
    tags: tags
    properties: {
      registrationEnabled: false
      virtualNetwork: {
        id: spokeVnetId
      }
    }
  }
]
