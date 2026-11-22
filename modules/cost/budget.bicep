// Monthly cost budget on the platform resource group. Alerts go to the
// platform action group at 80% of actual spend and when the forecast says
// the month will end over budget, so overspend is noticed mid-month.

@description('Monthly budget in the billing currency.')
@minValue(1)
param amount int

@description('First day of the first budget month, yyyy-MM-01. Cannot be in the past at creation.')
param startDate string
param actionGroupId string

@description('Extra email recipients. The action group is always notified.')
param contactEmails string[] = []

resource budget 'Microsoft.Consumption/budgets@2023-11-01' = {
  name: 'budget-${resourceGroup().name}'
  properties: {
    category: 'Cost'
    amount: amount
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: startDate
    }
    notifications: {
      actual80: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 80
        thresholdType: 'Actual'
        contactGroups: [actionGroupId]
        contactEmails: contactEmails
      }
      forecast100: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 100
        thresholdType: 'Forecasted'
        contactGroups: [actionGroupId]
        contactEmails: contactEmails
      }
    }
  }
}
