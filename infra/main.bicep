// Subscription-scope entry point. Creates the hub and platform resource
// groups and composes the modules. Deploy it as a deployment stack
// (see scripts/deploy.sh) so removed resources are cleaned up.

targetScope = 'subscription'

import { environment, requiredTags, nodePool, resourceName, uniqueAlnumName, regionCodes, regionDisplayNames } from '../modules/shared/types.bicep'

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

@description('Monthly cost budget for the platform resource group. 0 disables it.')
param monthlyBudget int = 0
@description('First budget month, yyyy-MM-01.')
param budgetStartDate string = ''

@description('Private Azure OpenAI account and its model deployments. Off when empty.')
param openAiDeployments {
  name: string
  model: string
  version: string
  sku: ('Standard' | 'GlobalStandard' | 'DataZoneStandard')
  capacity: int
}[] = []

@description('Service accounts that get a federated identity with Key Vault read access.')
param workloadIdentities {
  namespace: string
  serviceAccountName: string
  @description('Also grant Cognitive Services OpenAI User on the platform account.')
  openAi: bool?
}[] = []

var region = regionCodes[?location] ?? location
var hubRgName = resourceName('rg', '${workload}-hub', env, region)
var platformRgName = resourceName('rg', workload, env, region)
var keyVaultZone = 'privatelink.vaultcore.azure.net'
var acrZone = 'privatelink.azurecr.io'
var openAiZone = 'privatelink.openai.azure.com'
var enableOpenAi = !empty(openAiDeployments)
var privateDnsZones = concat([keyVaultZone, acrZone], enableOpenAi ? [openAiZone] : [])

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
    privateDnsZones: privateDnsZones
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
    privateDnsZoneNames: privateDnsZones
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

module openAi '../modules/ai/openai.bicep' = if (enableOpenAi) {
  name: 'openai'
  scope: platformRg
  params: {
    location: location
    env: env
    tags: tags
    name: uniqueAlnumName('oai', workload, env, platformRg.id, 40)
    privateEndpointSubnetId: spoke.outputs.privateEndpointSubnetId
    privateDnsZoneId: hub.outputs.privateDnsZoneIds[?openAiZone] ?? ''
    logAnalyticsId: monitoring.outputs.logAnalyticsId
    deployments: openAiDeployments
    actionGroupId: monitoring.outputs.actionGroupId
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
      openAiAccountName: enableOpenAi && (wi.?openAi ?? false) ? openAi!.outputs.name : ''
    }
  }
]

module serviceHealth '../modules/monitoring/service-health.bicep' = {
  name: 'service-health'
  scope: platformRg
  params: {
    tags: tags
    name: resourceName('alert-svchealth', workload, env, region)
    actionGroupId: monitoring.outputs.actionGroupId
    regions: [regionDisplayNames[?location] ?? location]
  }
}

module budget '../modules/cost/budget.bicep' = if (monthlyBudget > 0) {
  name: 'budget'
  scope: platformRg
  params: {
    amount: monthlyBudget
    startDate: budgetStartDate
    actionGroupId: monitoring.outputs.actionGroupId
    contactEmails: alertEmails
  }
}

output platformResourceGroup string = platformRg.name
output clusterName string = aks.outputs.name
output acrLoginServer string = registry.outputs.loginServer
output keyVaultUri string = keyVault.outputs.uri
output openAiEndpoint string = enableOpenAi ? openAi!.outputs.endpoint : ''
output workloadIdentityClientIds array = [
  for (wi, i) in workloadIdentities: {
    serviceAccount: '${wi.namespace}/${wi.serviceAccountName}'
    clientId: identities[i].outputs.clientId
  }
]
