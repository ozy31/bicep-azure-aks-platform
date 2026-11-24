// Azure Service Health alert for the services this platform runs on, in
// its region. An Azure-side incident then reaches the same action group as
// our own alerts, instead of being found later on the status page.

import { requiredTags } from '../shared/types.bicep'

param tags requiredTags
param name string
param actionGroupId string

@description('Region display names, e.g. "West Europe". Global incidents are always included.')
@minLength(1)
param regions string[]

@description('Service names as Service Health reports them.')
param services string[] = [
  'Azure Kubernetes Service (AKS)'
  'Key Vault'
  'Container Registry'
  'Virtual Network'
  'Azure Monitor'
  'Log Analytics'
]

resource serviceHealth 'Microsoft.Insights/activityLogAlerts@2020-10-01' = {
  name: name
  location: 'global'
  tags: tags
  properties: {
    enabled: true
    description: 'Azure incidents, required actions and planned maintenance for the AKS platform.'
    scopes: [subscription().id]
    condition: {
      allOf: [
        { field: 'category', equals: 'ServiceHealth' }
        {
          anyOf: [
            { field: 'properties.incidentType', equals: 'Incident' }
            { field: 'properties.incidentType', equals: 'ActionRequired' }
            { field: 'properties.incidentType', equals: 'Maintenance' }
            { field: 'properties.incidentType', equals: 'Security' }
          ]
        }
        { field: 'properties.impactedServices[*].ServiceName', containsAny: services }
        {
          field: 'properties.impactedServices[*].ImpactedRegions[*].RegionName'
          containsAny: union(regions, ['Global'])
        }
      ]
    }
    actions: {
      actionGroups: [{ actionGroupId: actionGroupId }]
    }
  }
}

output id string = serviceHealth.id
