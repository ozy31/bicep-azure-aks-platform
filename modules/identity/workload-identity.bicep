// A user-assigned identity federated with one Kubernetes service account,
// plus Key Vault Secrets User on the platform vault. Pods using that service
// account get Entra ID tokens without any stored secret. Optionally the
// identity may also call the platform's Azure OpenAI deployments.

import { requiredTags } from '../shared/types.bicep'

param location string
param tags requiredTags
param name string
param oidcIssuerUrl string
param namespace string
param serviceAccountName string

@description('Key Vault to grant read access to secrets. Empty skips the grant.')
param keyVaultName string = ''

@description('Azure OpenAI account to grant inference access to. Empty skips the grant.')
param openAiAccountName string = ''

var secretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'
// Cognitive Services OpenAI User: call deployed models, no management access.
var openAiUserRoleId = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: name
  location: location
  tags: tags
}

resource federation 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: identity
  name: '${namespace}-${serviceAccountName}'
  properties: {
    issuer: oidcIssuerUrl
    subject: 'system:serviceaccount:${namespace}:${serviceAccountName}'
    audiences: ['api://AzureADTokenExchange']
  }
}

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' existing = if (!empty(keyVaultName)) {
  name: keyVaultName
}

resource secretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(keyVaultName)) {
  name: guid(vault.id, identity.id, secretsUserRoleId)
  scope: vault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', secretsUserRoleId)
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource openAiAccount 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = if (!empty(openAiAccountName)) {
  name: openAiAccountName
}

resource openAiUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(openAiAccountName)) {
  name: guid(openAiAccount.id, identity.id, openAiUserRoleId)
  scope: openAiAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', openAiUserRoleId)
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

@description('Annotate the service account with azure.workload.identity/client-id set to this value.')
output clientId string = identity.properties.clientId
