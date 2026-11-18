#!/usr/bin/env python3
"""Asserts security baselines on the compiled ARM template.

The linter checks Bicep style; these checks pin down the decisions that make
the platform private and keyless, so a refactor cannot quietly turn one off.
They run against `az bicep build` output and need no Azure subscription.

Usage: python3 tests/test_template.py out/main.json
"""

import json
import sys
import unittest

TEMPLATE_PATH = sys.argv.pop(1) if len(sys.argv) > 1 else "out/main.json"

# Child or extension resources that do not take tags.
UNTAGGED_TYPES = {
    "Microsoft.Authorization/roleAssignments",
    "Microsoft.Insights/diagnosticSettings",
    "Microsoft.Insights/dataCollectionRuleAssociations",
    "Microsoft.Network/virtualNetworks/virtualNetworkPeerings",
    "Microsoft.Network/privateEndpoints/privateDnsZoneGroups",
    "Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials",
    "Microsoft.ContainerService/managedClusters/agentPools",
    "Microsoft.Resources/deployments",
}


def walk(template, module_path="main"):
    """Yields (module_path, symbolic_name, resource) for every resource,
    descending into nested module deployments."""
    resources = template.get("resources", {})
    items = resources.items() if isinstance(resources, dict) else enumerate(resources)
    for name, resource in items:
        if resource.get("type") == "Microsoft.Resources/deployments":
            nested = resource.get("properties", {}).get("template")
            if nested:
                yield from walk(nested, f"{module_path}/{name}")
        yield module_path, name, resource


def load():
    with open(TEMPLATE_PATH, encoding="utf-8") as handle:
        return list(walk(json.load(handle)))


RESOURCES = load()


def of_type(resource_type):
    found = [r for _, _, r in RESOURCES if r.get("type") == resource_type and not r.get("existing")]
    if not found:
        raise AssertionError(f"no {resource_type} in template")
    return found


class SecurityBaseline(unittest.TestCase):
    def test_aks_is_private_and_entra_only(self):
        for cluster in of_type("Microsoft.ContainerService/managedClusters"):
            props = cluster["properties"]
            self.assertIs(props["disableLocalAccounts"], True)
            self.assertIs(props["apiServerAccessProfile"]["enablePrivateCluster"], True)
            self.assertIs(props["apiServerAccessProfile"]["enablePrivateClusterPublicFQDN"], False)
            self.assertIs(props["aadProfile"]["managed"], True)
            self.assertIs(props["aadProfile"]["enableAzureRBAC"], True)

    def test_aks_has_workload_identity(self):
        for cluster in of_type("Microsoft.ContainerService/managedClusters"):
            props = cluster["properties"]
            self.assertIs(props["oidcIssuerProfile"]["enabled"], True)
            self.assertIs(props["securityProfile"]["workloadIdentity"]["enabled"], True)

    def test_aks_system_pool_is_tainted(self):
        for cluster in of_type("Microsoft.ContainerService/managedClusters"):
            system = cluster["properties"]["agentPoolProfiles"][0]
            self.assertEqual(system["mode"], "System")
            self.assertIn("CriticalAddonsOnly=true:NoSchedule", system["nodeTaints"])

    def test_aks_uses_overlay_and_network_policy(self):
        for cluster in of_type("Microsoft.ContainerService/managedClusters"):
            net = cluster["properties"]["networkProfile"]
            self.assertEqual(net["networkPluginMode"], "overlay")
            self.assertEqual(net["networkPolicy"], "cilium")

    def test_key_vault_is_private_and_rbac(self):
        for vault in of_type("Microsoft.KeyVault/vaults"):
            props = vault["properties"]
            self.assertEqual(props["publicNetworkAccess"], "Disabled")
            self.assertIs(props["enableRbacAuthorization"], True)
            self.assertEqual(props["networkAcls"]["defaultAction"], "Deny")

    def test_registry_is_private_without_admin_user(self):
        for registry in of_type("Microsoft.ContainerRegistry/registries"):
            props = registry["properties"]
            self.assertIs(props["adminUserEnabled"], False)
            self.assertEqual(props["publicNetworkAccess"], "Disabled")
            self.assertEqual(props["policies"]["exportPolicy"]["status"], "disabled")

    def test_log_analytics_disables_shared_keys(self):
        for workspace in of_type("Microsoft.OperationalInsights/workspaces"):
            self.assertIs(workspace["properties"]["features"]["disableLocalAuth"], True)

    def test_every_private_endpoint_registers_dns(self):
        endpoints = of_type("Microsoft.Network/privateEndpoints")
        zone_groups = of_type("Microsoft.Network/privateEndpoints/privateDnsZoneGroups")
        self.assertEqual(len(endpoints), len(zone_groups))

    def test_role_assignments_are_scoped_to_service_principals(self):
        for assignment in of_type("Microsoft.Authorization/roleAssignments"):
            self.assertEqual(assignment["properties"]["principalType"], "ServicePrincipal")
            self.assertIn("scope", assignment, "role assignments must not default to the resource group")

    def test_taggable_resources_carry_tags(self):
        missing = [
            f"{path}:{name}"
            for path, name, r in RESOURCES
            if not r.get("existing") and r.get("type") not in UNTAGGED_TYPES and "tags" not in r
        ]
        self.assertEqual(missing, [])

    def test_no_secure_outputs_or_keys_in_outputs(self):
        with open(TEMPLATE_PATH, encoding="utf-8") as handle:
            text = handle.read()
        for needle in ("listKeys(", "listCredentials(", "listAdminCredentials("):
            self.assertNotIn(needle, text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
