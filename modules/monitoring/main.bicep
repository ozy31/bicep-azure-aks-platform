// Log Analytics for logs, an Azure Monitor workspace for managed Prometheus,
// and an action group that alerts route to.

import { environment, requiredTags } from '../shared/types.bicep'

param location string
param env environment
param tags requiredTags
param logAnalyticsName string
param monitorWorkspaceName string
param actionGroupName string

@description('Retention for the Log Analytics workspace, in days.')
@minValue(30)
@maxValue(730)
param retentionInDays int = env == 'prod' ? 90 : 30

@description('Daily ingestion cap in GB. -1 removes the cap.')
param dailyQuotaGb int = env == 'prod' ? -1 : 5

@description('Email receivers for the platform action group.')
param alertEmails string[] = []

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
    workspaceCapping: {
      dailyQuotaGb: dailyQuotaGb
    }
    features: {
      disableLocalAuth: true
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

resource monitorWorkspace 'Microsoft.Monitor/accounts@2023-04-03' = {
  name: monitorWorkspaceName
  location: location
  tags: tags
}

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: actionGroupName
  location: 'global'
  tags: tags
  properties: {
    groupShortName: take('plat${env}', 12)
    enabled: true
    emailReceivers: [
      for (email, i) in alertEmails: {
        name: 'email-${i}'
        emailAddress: email
        useCommonAlertSchema: true
      }
    ]
  }
}

output logAnalyticsId string = logAnalytics.id
output monitorWorkspaceId string = monitorWorkspace.id
output actionGroupId string = actionGroup.id
