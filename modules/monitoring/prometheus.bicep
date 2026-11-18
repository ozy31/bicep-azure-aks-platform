// Wires an AKS cluster to Azure Monitor managed Prometheus: data collection
// endpoint and rule, the association with the cluster, and a small set of
// platform alert rules routed to the action group.

import { requiredTags } from '../shared/types.bicep'

param location string
param tags requiredTags
param clusterName string
param monitorWorkspaceId string
param actionGroupId string

resource cluster 'Microsoft.ContainerService/managedClusters@2024-09-01' existing = {
  name: clusterName
}

resource endpoint 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' = {
  name: take('MSProm-${location}-${clusterName}', 44)
  location: location
  tags: tags
  kind: 'Linux'
  properties: {}
}

resource rule 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: take('MSProm-${location}-${clusterName}', 64)
  location: location
  tags: tags
  kind: 'Linux'
  properties: {
    dataCollectionEndpointId: endpoint.id
    dataSources: {
      prometheusForwarder: [
        {
          name: 'PrometheusDataSource'
          streams: ['Microsoft-PrometheusMetrics']
          labelIncludeFilter: {}
        }
      ]
    }
    destinations: {
      monitoringAccounts: [
        {
          name: 'MonitoringAccount1'
          accountResourceId: monitorWorkspaceId
        }
      ]
    }
    dataFlows: [
      {
        streams: ['Microsoft-PrometheusMetrics']
        destinations: ['MonitoringAccount1']
      }
    ]
  }
}

resource association 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = {
  name: 'ContainerInsightsMetricsExtension'
  scope: cluster
  properties: {
    dataCollectionRuleId: rule.id
  }
}

resource platformAlerts 'Microsoft.AlertsManagement/prometheusRuleGroups@2023-03-01' = {
  name: 'platform-alerts-${clusterName}'
  location: location
  tags: tags
  properties: {
    clusterName: clusterName
    scopes: [monitorWorkspaceId, cluster.id]
    interval: 'PT1M'
    enabled: true
    rules: [
      {
        alert: 'KubePodCrashLooping'
        expression: 'max_over_time(kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff", job="kube-state-metrics"}[5m]) >= 1'
        for: 'PT15M'
        severity: 3
        labels: { team: 'platform' }
        annotations: {
          description: 'Pod {{ $labels.namespace }}/{{ $labels.pod }} is crash looping.'
        }
        actions: [{ actionGroupId: actionGroupId }]
        resolveConfiguration: { autoResolved: true, timeToResolve: 'PT10M' }
      }
      {
        alert: 'KubeNodeNotReady'
        expression: 'kube_node_status_condition{job="kube-state-metrics", condition="Ready", status="true"} == 0'
        for: 'PT15M'
        severity: 2
        labels: { team: 'platform' }
        annotations: {
          description: 'Node {{ $labels.node }} has been NotReady for 15 minutes.'
        }
        actions: [{ actionGroupId: actionGroupId }]
        resolveConfiguration: { autoResolved: true, timeToResolve: 'PT10M' }
      }
      {
        alert: 'NodeFilesystemAlmostFull'
        expression: '(node_filesystem_avail_bytes{job="node", fstype!=""} / node_filesystem_size_bytes{job="node", fstype!=""}) < 0.10'
        for: 'PT30M'
        severity: 2
        labels: { team: 'platform' }
        annotations: {
          description: 'Filesystem {{ $labels.mountpoint }} on {{ $labels.instance }} has less than 10% free.'
        }
        actions: [{ actionGroupId: actionGroupId }]
        resolveConfiguration: { autoResolved: true, timeToResolve: 'PT10M' }
      }
      {
        alert: 'KubePersistentVolumeFillingUp'
        expression: 'kubelet_volume_stats_available_bytes{job="kubelet"} / kubelet_volume_stats_capacity_bytes{job="kubelet"} < 0.05'
        for: 'PT5M'
        severity: 1
        labels: { team: 'platform' }
        annotations: {
          description: 'PVC {{ $labels.namespace }}/{{ $labels.persistentvolumeclaim }} has less than 5% free.'
        }
        actions: [{ actionGroupId: actionGroupId }]
        resolveConfiguration: { autoResolved: true, timeToResolve: 'PT10M' }
      }
    ]
  }
}
