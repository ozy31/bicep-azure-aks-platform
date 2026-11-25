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

@description('Weekly maintenance window for automatic Kubernetes and node image upgrades (UTC).')
param maintenanceWindow {
  dayOfWeek: ('Monday' | 'Tuesday' | 'Wednesday' | 'Thursday' | 'Friday' | 'Saturday' | 'Sunday')
  startTime: string
  durationHours: int
} = {
  dayOfWeek: 'Sunday'
  startTime: '02:00'
  durationHours: 4
}

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

// With a custom vnet the control plane manages load balancer IPs and, with
// UDR egress, the route table. Network Contributor on the node subnet covers both.
// The subnet must live in this resource group.
resource nodeVnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: split(nodeSubnetId, '/')[8]

  resource nodeSubnet 'subnets' existing = {
    name: last(split(nodeSubnetId, '/'))
  }
}

resource subnetNetworkContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(nodeSubnetId, controlPlaneIdentity.id, '4d97b98b-1d4f-4787-a291-c67834d212e7')
  scope: nodeVnet::nodeSubnet
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '4d97b98b-1d4f-4787-a291-c67834d212e7'
    )
    principalId: controlPlaneIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Surge a third of each pool, give pods up to 30 minutes to drain (a PDB
// that never allows eviction fails the upgrade instead of hanging it), and
// wait 5 minutes after each batch so a bad node image shows up before the
// next batch is drained.
var upgradeSettings = {
  maxSurge: '33%'
  drainTimeoutInMinutes: 30
  nodeSoakDurationInMinutes: 5
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
      // Defender for Containers runtime threat detection. Billed per vCore,
      // so it is on in prod only; dev clusters still get image cleanup and policy.
      defender: env == 'prod'
        ? {
            logAnalyticsWorkspaceResourceId: logAnalyticsId
            securityMonitoring: {
              enabled: true
            }
          }
        : null
    }
    // Pack nodes tightly and remove idle ones after 10 minutes; keep zone
    // pools balanced so a zone outage does not take most of a workload.
    autoScalerProfile: {
      expander: 'least-waste'
      'balance-similar-node-groups': 'true'
      'scale-down-unneeded-time': '10m'
      'scale-down-delay-after-add': '10m'
      'skip-nodes-with-local-storage': 'false'
      'max-graceful-termination-sec': '600'
    }
    // KEDA scales deployments on queue depth or Prometheus queries instead of
    // CPU only (inference queues, batch jobs); VPA recommends requests from
    // real usage. Both are managed add-ons, upgraded with the cluster.
    workloadAutoScalerProfile: {
      keda: {
        enabled: true
      }
      verticalPodAutoscaler: {
        enabled: true
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
        upgradeSettings: upgradeSettings
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
    // Splits the cluster bill by namespace in Cost Management. The add-on
    // needs the Standard tier, which only prod runs on.
    metricsProfile: {
      costAnalysis: {
        enabled: env == 'prod'
      }
    }
  }
  dependsOn: [managedIdentityOperator, subnetNetworkContributor]
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
      upgradeSettings: upgradeSettings
    }
  }
]

// Automatic upgrades only start inside these windows, so a patch release
// never rolls nodes in the middle of a business day. Node images update a
// few hours after the control plane, never both at once.
resource upgradeSchedule 'Microsoft.ContainerService/managedClusters/maintenanceConfigurations@2024-09-01' = {
  parent: cluster
  name: 'aksManagedAutoUpgradeSchedule'
  properties: {
    maintenanceWindow: {
      schedule: {
        weekly: {
          dayOfWeek: maintenanceWindow.dayOfWeek
          intervalWeeks: 1
        }
      }
      startTime: maintenanceWindow.startTime
      durationHours: maintenanceWindow.durationHours
      utcOffset: '+00:00'
    }
  }
}

resource nodeOsSchedule 'Microsoft.ContainerService/managedClusters/maintenanceConfigurations@2024-09-01' = {
  parent: cluster
  name: 'aksManagedNodeOSUpgradeSchedule'
  properties: {
    maintenanceWindow: {
      schedule: {
        weekly: {
          dayOfWeek: maintenanceWindow.dayOfWeek
          intervalWeeks: 1
        }
      }
      startTime: format(
        '{0:D2}:00',
        (int(split(maintenanceWindow.startTime, ':')[0]) + maintenanceWindow.durationHours) % 24
      )
      durationHours: maintenanceWindow.durationHours
      utcOffset: '+00:00'
    }
  }
  dependsOn: [upgradeSchedule]
}

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
