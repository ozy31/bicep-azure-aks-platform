// Subscription-scope entry point. Creates the hub and platform resource
// groups and composes the modules. Deploy it as a deployment stack
// (see scripts/deploy.sh) so removed resources are cleaned up.

targetScope = 'subscription'

import { environment, requiredTags, nodePool, resourceName, uniqueAlnumName, regionCodes } from '../modules/shared/types.bicep'

param location string
param env environment
param workload string = 'aks'
param tags requiredTags

@description('Hub address space, at least a /24.')
param hubAddressPrefix string

@description('Spoke address space, at least a /21 (nodes /22 + private endpoints /24).')
param spokeAddressPrefix string

@description('Private IP of an existing hub firewall/NVA. Empty keeps load balancer egress.')
param firewallPrivateIp string = ''

param kubernetesVersion string
param nodePools nodePool[]
param adminGroupObjectIds string[] = []
param alertEmails string[] = []

@description('Service accounts that get a federated identity with Key Vault read access.')
param workloadIdentities { namespace: string, serviceAccountName: string }[] = []

var region = regionCodes[?location] ?? location
var hubRgName = resourceName('rg', '${workload}-hub', env, region)
var platformRgName = resourceName('rg', workload, env, region)
var keyVaultZone = 'privatelink.vaultcore.azure.net'
var acrZone = 'privatelink.azurecr.io'

resource hubRg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: hubRgName
  location: location
  tags: tags
}

resource platformRg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: platformRgName
  location: location
  tags: tags
}

module monitoring '../modules/monitoring/main.bicep' = {
  name: 'monitoring'
  scope: platformRg
  params: {
    location: location
    env: env
    tags: tags
    logAnalyticsName: resourceName('log', workload, env, region)
    monitorWorkspaceName: resourceName('amw', workload, env, region)
    actionGroupName: resourceName('ag', workload, env, region)
    alertEmails: alertEmails
  }
}

module hub '../modules/network/hub.bicep' = {
  name: 'hub'
  scope: hubRg
  params: {
    location: location
    tags: tags
    vnetName: resourceName('vnet', '${workload}-hub', env, region)
    addressPrefix: hubAddressPrefix
    logAnalyticsId: monitoring.outputs.logAnalyticsId
    privateDnsZones: [keyVaultZone, acrZone]
  }
}

module spoke '../modules/network/spoke.bicep' = {
  name: 'spoke'
  scope: platformRg
  params: {
    location: location
    tags: tags
    vnetName: resourceName('vnet', workload, env, region)
    addressPrefix: spokeAddressPrefix
    logAnalyticsId: monitoring.outputs.logAnalyticsId
    hubResourceGroupName: hubRg.name
    hubVnetId: hub.outputs.vnetId
    hubVnetName: hub.outputs.vnetName
    privateDnsZoneNames: [keyVaultZone, acrZone]
    firewallPrivateIp: firewallPrivateIp
  }
}

module keyVault '../modules/security/keyvault.bicep' = {
  name: 'keyvault'
  scope: platformRg
  params: {
    location: location
    env: env
    tags: tags
    name: uniqueAlnumName('kv', workload, env, platformRg.id, 24)
    privateEndpointSubnetId: spoke.outputs.privateEndpointSubnetId
    privateDnsZoneId: hub.outputs.privateDnsZoneIds[keyVaultZone]
    logAnalyticsId: monitoring.outputs.logAnalyticsId
  }
}

module registry '../modules/registry/acr.bicep' = {
  name: 'registry'
  scope: platformRg
  params: {
    location: location
    env: env
    tags: tags
    name: uniqueAlnumName('acr', workload, env, platformRg.id, 50)
    privateEndpointSubnetId: spoke.outputs.privateEndpointSubnetId
    privateDnsZoneId: hub.outputs.privateDnsZoneIds[acrZone]
    logAnalyticsId: monitoring.outputs.logAnalyticsId
  }
}

module aks '../modules/aks/cluster.bicep' = {
  name: 'aks'
  scope: platformRg
  params: {
    location: location
    env: env
    tags: tags
    name: resourceName('aks', workload, env, region)
    kubernetesVersion: kubernetesVersion
    nodeSubnetId: spoke.outputs.nodeSubnetId
    logAnalyticsId: monitoring.outputs.logAnalyticsId
    nodePools: nodePools
    userDefinedRouting: !empty(firewallPrivateIp)
    adminGroupObjectIds: adminGroupObjectIds
  }
}

module acrPull '../modules/identity/acr-pull.bicep' = {
  name: 'acr-pull'
  scope: platformRg
  params: {
    registryName: registry.outputs.name
    kubeletPrincipalId: aks.outputs.kubeletPrincipalId
  }
}

module prometheus '../modules/monitoring/prometheus.bicep' = {
  name: 'prometheus'
  scope: platformRg
  params: {
    location: location
    tags: tags
    clusterName: aks.outputs.name
    monitorWorkspaceId: monitoring.outputs.monitorWorkspaceId
    actionGroupId: monitoring.outputs.actionGroupId
  }
}

module identities '../modules/identity/workload-identity.bicep' = [
  for wi in workloadIdentities: {
    name: 'wi-${wi.namespace}-${wi.serviceAccountName}'
    scope: platformRg
    params: {
      location: location
      tags: tags
      name: 'id-${wi.namespace}-${wi.serviceAccountName}-${env}'
      oidcIssuerUrl: aks.outputs.oidcIssuerUrl
      namespace: wi.namespace
      serviceAccountName: wi.serviceAccountName
      keyVaultName: keyVault.outputs.name
    }
  }
]

output platformResourceGroup string = platformRg.name
output clusterName string = aks.outputs.name
output acrLoginServer string = registry.outputs.loginServer
output keyVaultUri string = keyVault.outputs.uri
output workloadIdentityClientIds array = [
  for (wi, i) in workloadIdentities: {
    serviceAccount: '${wi.namespace}/${wi.serviceAccountName}'
    clientId: identities[i].outputs.clientId
  }
]
