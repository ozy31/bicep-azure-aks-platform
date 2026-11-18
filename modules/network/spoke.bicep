// Spoke network for the AKS workload: node and private-endpoint subnets,
// an NSG, optional forced tunnelling to the hub firewall, peering in both
// directions and links to the hub's private DNS zones.

import { requiredTags } from '../shared/types.bicep'

param location string
param tags requiredTags
param vnetName string
param addressPrefix string
param logAnalyticsId string

param hubResourceGroupName string
param hubVnetId string
param hubVnetName string
param privateDnsZoneNames string[]

@description('Private IP of the hub firewall. Empty keeps default internet egress.')
param firewallPrivateIp string = ''

var forceTunnel = !empty(firewallPrivateIp)

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${vnetName}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'deny-internet-inbound'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource routeTable 'Microsoft.Network/routeTables@2024-05-01' = if (forceTunnel) {
  name: 'rt-${vnetName}'
  location: location
  tags: tags
  properties: {
    disableBgpRoutePropagation: true
    routes: [
      {
        name: 'default-via-firewall'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: firewallPrivateIp
        }
      }
    ]
  }
}

module vnet 'vnet.bicep' = {
  name: 'spoke-vnet'
  params: {
    location: location
    tags: tags
    name: vnetName
    addressPrefixes: [addressPrefix]
    logAnalyticsId: logAnalyticsId
    subnets: [
      {
        // A /22 for nodes; pods use Azure CNI Overlay and do not consume vnet IPs.
        name: 'snet-aks-nodes'
        addressPrefix: cidrSubnet(addressPrefix, 22, 0)
        networkSecurityGroupId: nsg.id
        routeTableId: forceTunnel ? routeTable.id : null
      }
      {
        name: 'snet-private-endpoints'
        addressPrefix: cidrSubnet(addressPrefix, 24, 4)
        networkSecurityGroupId: nsg.id
        privateEndpointNetworkPolicies: 'Disabled'
      }
    ]
  }
}

resource spokeVnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName
  dependsOn: [vnet]
}

resource spokeToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: spokeVnet
  name: 'peer-to-${hubVnetName}'
  properties: {
    remoteVirtualNetwork: {
      id: hubVnetId
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    useRemoteGateways: false
  }
}

module hubSide 'hub-attach.bicep' = {
  name: 'hub-attach-${vnetName}'
  scope: resourceGroup(hubResourceGroupName)
  params: {
    hubVnetName: hubVnetName
    spokeVnetId: vnet.outputs.id
    spokeVnetName: vnetName
    privateDnsZoneNames: privateDnsZoneNames
    tags: tags
  }
}

output vnetId string = vnet.outputs.id
output nodeSubnetId string = vnet.outputs.subnetIds['snet-aks-nodes']
output privateEndpointSubnetId string = vnet.outputs.subnetIds['snet-private-endpoints']
