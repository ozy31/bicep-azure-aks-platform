// Hub network: shared private DNS zones and a subnet reserved for the
// firewall or NVA that spoke egress is routed through.

import { requiredTags } from '../shared/types.bicep'

param location string
param tags requiredTags
param vnetName string
param addressPrefix string
param logAnalyticsId string

@description('Private DNS zones hosted in the hub and linked to every spoke.')
param privateDnsZones string[] = [
  'privatelink.vaultcore.azure.net'
  'privatelink.azurecr.io'
]

module vnet 'vnet.bicep' = {
  name: 'hub-vnet'
  params: {
    location: location
    tags: tags
    name: vnetName
    addressPrefixes: [addressPrefix]
    logAnalyticsId: logAnalyticsId
    subnets: [
      {
        // Name is fixed by Azure Firewall.
        name: 'AzureFirewallSubnet'
        addressPrefix: cidrSubnet(addressPrefix, 26, 0)
      }
      {
        name: 'snet-shared'
        addressPrefix: cidrSubnet(addressPrefix, 26, 1)
        privateEndpointNetworkPolicies: 'Disabled'
      }
    ]
  }
}

resource zones 'Microsoft.Network/privateDnsZones@2024-06-01' = [
  for zone in privateDnsZones: {
    name: zone
    location: 'global'
    tags: tags
  }
]

resource hubLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for (zone, i) in privateDnsZones: {
    parent: zones[i]
    name: 'link-${vnetName}'
    location: 'global'
    tags: tags
    properties: {
      registrationEnabled: false
      virtualNetwork: {
        id: vnet.outputs.id
      }
    }
  }
]

output vnetId string = vnet.outputs.id
output vnetName string = vnet.outputs.name
output firewallSubnetId string = vnet.outputs.subnetIds.AzureFirewallSubnet
// Keyed by zone name so consumers can look up the zone they need.
// dependsOn-free: zone IDs are deterministic within this resource group.
output privateDnsZoneIds object = toObject(
  privateDnsZones,
  zone => zone,
  zone => resourceId('Microsoft.Network/privateDnsZones', zone)
)
