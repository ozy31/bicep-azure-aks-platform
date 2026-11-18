// Shared user-defined types and naming helpers.
// Imported by every module with `import { ... } from '../shared/types.bicep'`.

@export()
@description('Short environment code. Drives naming, SKUs and protection settings.')
type environment = 'dev' | 'prod'

@export()
@description('Tags every resource must carry. Extra keys are allowed.')
type requiredTags = {
  environment: environment
  owner: string
  costCenter: string
  *: string
}

@export()
@description('A subnet definition for a virtual network module.')
type subnet = {
  name: string
  addressPrefix: string
  @description('Resource ID of a network security group to attach.')
  networkSecurityGroupId: string?
  @description('Resource ID of a route table to attach.')
  routeTableId: string?
  @description('Set to Disabled on subnets that host private endpoints.')
  privateEndpointNetworkPolicies: ('Enabled' | 'Disabled')?
  delegation: string?
}

@export()
@description('An AKS node pool. The first pool in the list becomes the system pool.')
type nodePool = {
  @minLength(1)
  @maxLength(12)
  name: string
  vmSize: string
  @minValue(1)
  minCount: int
  @maxValue(100)
  maxCount: int
  @description('Availability zones. Leave empty for regions without zones.')
  zones: string[]
  osDiskSizeGB: int?
  @description('Taints, e.g. "workload=batch:NoSchedule".')
  taints: string[]?
  labels: { *: string }?
}

@export()
@description('Builds a resource name following <abbreviation>-<workload>-<env>-<region>.')
func resourceName(abbreviation string, workload string, env environment, region string) string =>
  toLower('${abbreviation}-${workload}-${env}-${region}')

@export()
@description('Builds a globally unique, alphanumeric name (Key Vault, ACR, storage).')
func uniqueAlnumName(prefix string, workload string, env environment, seed string, maxLength int) string =>
  take(toLower('${prefix}${replace(workload, '-', '')}${env}${uniqueString(seed)}'), maxLength)

@export()
@description('Short region codes keep names under length limits.')
var regionCodes = {
  westeurope: 'weu'
  northeurope: 'neu'
  swedencentral: 'sdc'
  germanywestcentral: 'gwc'
  uksouth: 'uks'
  eastus2: 'eus2'
}
