// Private AKS cluster: Entra ID-only access (local accounts disabled),
// Azure RBAC for Kubernetes, workload identity, Azure CNI Overlay with the
// Cilium dataplane, and managed Prometheus metrics.

import { environment, requiredTags, nodePool } from '../shared/types.bicep'

param location string
param env environment
param tags requiredTags
param name string

@description('Kubernetes minor version, e.g. "1.31". Patch upgrades are automatic.')
param kubernetesVersion string
param nodeSubnetId string
param logAnalyticsId string

@description('Node pools. The first one becomes the system pool (CriticalAddonsOnly).')
@minLength(1)
param nodePools nodePool[]

@description('Use the hub firewall for egress (requires a UDR on the node subnet).')
param userDefinedRouting bool = false

@description('Entra ID group object IDs that get cluster-admin through Azure RBAC.')
param adminGroupObjectIds string[] = []

param podCidr string = '10.244.0.0/16'
param serviceCidr string = '10.0.0.0/16'
param dnsServiceIp string = '10.0.0.10'

resource controlPlaneIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${name}-control-plane'
  location: location
  tags: tags
}

resource kubeletIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${name}-kubelet'
  location: location
  tags: tags
}

// The control plane assigns the kubelet identity to the node VMSS.
resource managedIdentityOperator 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(kubeletIdentity.id, controlPlaneIdentity.id, 'f1a07417-d97a-45cb-824c-7a7467783830')
  scope: kubeletIdentity
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'f1a07417-d97a-45cb-824c-7a7467783830'
    )
    principalId: controlPlaneIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

var systemPool = nodePools[0]
var userPools = skip(nodePools, 1)

resource cluster 'Microsoft.ContainerService/managedClusters@2024-09-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: 'Base'
    // Standard gives the financially backed API server SLA.
    tier: env == 'prod' ? 'Standard' : 'Free'
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${controlPlaneIdentity.id}': {}
    }
  }
  properties: {
    kubernetesVersion: kubernetesVersion
    dnsPrefix: name
    nodeResourceGroup: 'rg-${name}-nodes'
    identityProfile: {
      kubeletidentity: {
        resourceId: kubeletIdentity.id
        clientId: kubeletIdentity.properties.clientId
        objectId: kubeletIdentity.properties.principalId
      }
    }
    disableLocalAccounts: true
    enableRBAC: true
    aadProfile: {
      managed: true
      enableAzureRBAC: true
      adminGroupObjectIDs: adminGroupObjectIds
      tenantID: tenant().tenantId
    }
    apiServerAccessProfile: {
      enablePrivateCluster: true
      privateDNSZone: 'system'
      enablePrivateClusterPublicFQDN: false
    }
    oidcIssuerProfile: {
      enabled: true
    }
    securityProfile: {
      workloadIdentity: {
        enabled: true
      }
      imageCleaner: {
        enabled: true
        intervalHours: 48
      }
    }
    autoUpgradeProfile: {
      upgradeChannel: 'patch'
      nodeOSUpgradeChannel: 'NodeImage'
    }
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      networkDataplane: 'cilium'
      networkPolicy: 'cilium'
      podCidr: podCidr
      serviceCidr: serviceCidr
      dnsServiceIP: dnsServiceIp
      outboundType: userDefinedRouting ? 'userDefinedRouting' : 'loadBalancer'
      loadBalancerSku: 'standard'
    }
    agentPoolProfiles: [
      {
        name: systemPool.name
        mode: 'System'
        vmSize: systemPool.vmSize
        osType: 'Linux'
        osSKU: 'AzureLinux'
        osDiskType: 'Ephemeral'
        osDiskSizeGB: systemPool.?osDiskSizeGB ?? 128
        enableAutoScaling: true
        count: systemPool.minCount
        minCount: systemPool.minCount
        maxCount: systemPool.maxCount
        availabilityZones: systemPool.zones
        vnetSubnetID: nodeSubnetId
        maxPods: 110
        nodeTaints: ['CriticalAddonsOnly=true:NoSchedule']
        nodeLabels: systemPool.?labels ?? {}
        upgradeSettings: {
          maxSurge: '33%'
        }
      }
    ]
    addonProfiles: {
      omsagent: {
        enabled: true
        config: {
          logAnalyticsWorkspaceResourceID: logAnalyticsId
          useAADAuth: 'true'
        }
      }
      azureKeyvaultSecretsProvider: {
        enabled: true
        config: {
          enableSecretRotation: 'true'
          rotationPollInterval: '2m'
        }
      }
      azurepolicy: {
        enabled: true
      }
    }
    azureMonitorProfile: {
      metrics: {
        enabled: true
      }
    }
  }
  dependsOn: [managedIdentityOperator]
}

// User pools are separate resources so adding one never touches the system pool.
resource pools 'Microsoft.ContainerService/managedClusters/agentPools@2024-09-01' = [
  for pool in userPools: {
    parent: cluster
    name: pool.name
    properties: {
      mode: 'User'
      vmSize: pool.vmSize
      osType: 'Linux'
      osSKU: 'AzureLinux'
      osDiskType: 'Ephemeral'
      osDiskSizeGB: pool.?osDiskSizeGB ?? 128
      enableAutoScaling: true
      count: pool.minCount
      minCount: pool.minCount
      maxCount: pool.maxCount
      availabilityZones: pool.zones
      vnetSubnetID: nodeSubnetId
      maxPods: 110
      nodeTaints: pool.?taints ?? []
      nodeLabels: pool.?labels ?? {}
      upgradeSettings: {
        maxSurge: '33%'
      }
    }
  }
]

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: cluster
  properties: {
    workspaceId: logAnalyticsId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      { category: 'kube-audit-admin', enabled: true }
      { category: 'kube-apiserver', enabled: env == 'prod' }
      { category: 'guard', enabled: true }
      { category: 'cluster-autoscaler', enabled: true }
    ]
  }
}

output id string = cluster.id
output name string = cluster.name
output oidcIssuerUrl string = cluster.properties.oidcIssuerProfile.issuerURL
output controlPlanePrincipalId string = controlPlaneIdentity.properties.principalId
output kubeletPrincipalId string = kubeletIdentity.properties.principalId
