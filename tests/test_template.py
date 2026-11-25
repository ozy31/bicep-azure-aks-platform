#!/usr/bin/env python3
"""Asserts security baselines on the compiled ARM template.

The linter checks Bicep style; these checks pin down the decisions that make
the platform private and keyless, so a refactor cannot quietly turn one off.
They run against `az bicep build` output and need no Azure subscription.

Usage: python3 tests/test_template.py out/main.json
"""

import json
import shutil
import subprocess
import sys
import tempfile
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
    "Microsoft.ContainerService/managedClusters/maintenanceConfigurations",
    "Microsoft.Resources/deployments",
    "Microsoft.Consumption/budgets",
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


def templates(template):
    """Yields the template and every nested module template."""
    yield template
    for _, _, resource in walk(template):
        nested = resource.get("properties", {}).get("template")
        if resource.get("type") == "Microsoft.Resources/deployments" and nested:
            yield nested


with open(TEMPLATE_PATH, encoding="utf-8") as _handle:
    ROOT = json.load(_handle)

RESOURCES = list(walk(ROOT))
TEMPLATES = list(templates(ROOT))


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

    def test_aks_runs_defender_in_prod(self):
        for cluster in of_type("Microsoft.ContainerService/managedClusters"):
            defender = cluster["properties"]["securityProfile"]["defender"]
            # env is a parameter, so the compiled value is an expression.
            self.assertIn("equals(parameters('env'), 'prod')", defender)
            self.assertIn("securityMonitoring", defender)

    def test_aks_system_pool_is_tainted(self):
        for cluster in of_type("Microsoft.ContainerService/managedClusters"):
            system = cluster["properties"]["agentPoolProfiles"][0]
            self.assertEqual(system["mode"], "System")
            self.assertIn("CriticalAddonsOnly=true:NoSchedule", system["nodeTaints"])

    def test_autoscaler_balances_zones_and_scales_down(self):
        cluster = of_type("Microsoft.ContainerService/managedClusters")[0]
        profile = cluster["properties"]["autoScalerProfile"]
        self.assertEqual(profile["balance-similar-node-groups"], "true")
        self.assertEqual(profile["expander"], "least-waste")
        # emptyDir is scratch space here; it must not pin nodes forever.
        self.assertEqual(profile["skip-nodes-with-local-storage"], "false")
        # Pods get as long to stop on scale-down as on upgrade drains.
        self.assertLessEqual(int(profile["max-graceful-termination-sec"]), 30 * 60)

    def test_event_driven_and_vertical_autoscaling(self):
        cluster = of_type("Microsoft.ContainerService/managedClusters")[0]
        profile = cluster["properties"]["workloadAutoScalerProfile"]
        self.assertIs(profile["keda"]["enabled"], True)
        self.assertIs(profile["verticalPodAutoscaler"]["enabled"], True)

    def test_aks_uses_overlay_and_network_policy(self):
        for cluster in of_type("Microsoft.ContainerService/managedClusters"):
            net = cluster["properties"]["networkProfile"]
            self.assertEqual(net["networkPluginMode"], "overlay")
            self.assertEqual(net["networkPolicy"], "cilium")

    def test_node_upgrades_drain_and_soak(self):
        # Pools share one variable; check its value in the module that defines it.
        found = [t["variables"]["upgradeSettings"] for t in TEMPLATES if "upgradeSettings" in t.get("variables", {})]
        self.assertEqual(len(found), 1)
        settings = found[0]
        self.assertGreater(settings["nodeSoakDurationInMinutes"], 0)
        self.assertLessEqual(settings["drainTimeoutInMinutes"], 60)
        cluster = of_type("Microsoft.ContainerService/managedClusters")[0]
        pools = [cluster["properties"]["agentPoolProfiles"][0]]
        pools += [p["properties"] for p in of_type("Microsoft.ContainerService/managedClusters/agentPools")]
        for pool in pools:
            # Spot pools skip surge settings; every other pool uses the shared ones.
            self.assertIn("variables('upgradeSettings')", pool["upgradeSettings"])

    def test_spot_pools_are_deleted_on_eviction(self):
        pool = of_type("Microsoft.ContainerService/managedClusters/agentPools")[0]["properties"]
        self.assertIn("'Regular'", pool["scaleSetPriority"])
        self.assertIn("'Delete'", pool["scaleSetEvictionPolicy"])
        # Capping the price below on-demand would evict nodes on every price change.
        self.assertIn("json('-1')", pool["spotMaxPrice"])

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

    def test_auto_upgrades_run_in_maintenance_windows(self):
        cluster = of_type("Microsoft.ContainerService/managedClusters")[0]
        self.assertEqual(cluster["properties"]["autoUpgradeProfile"]["upgradeChannel"], "patch")
        names = {
            r["name"]
            for r in of_type("Microsoft.ContainerService/managedClusters/maintenanceConfigurations")
        }
        joined = " ".join(names)
        self.assertIn("aksManagedAutoUpgradeSchedule", joined)
        self.assertIn("aksManagedNodeOSUpgradeSchedule", joined)

    def test_node_image_window_follows_control_plane_window(self):
        schedules = {
            r["name"]: r for r in of_type("Microsoft.ContainerService/managedClusters/maintenanceConfigurations")
        }
        node_os = next(v for k, v in schedules.items() if "aksManagedNodeOSUpgradeSchedule" in k)
        self.assertIn("dependsOn", node_os)
        # Start time is derived from the control plane window, not a second literal.
        self.assertIn("maintenanceWindow", node_os["properties"]["maintenanceWindow"]["startTime"])

    def test_cost_analysis_follows_the_standard_tier(self):
        cluster = of_type("Microsoft.ContainerService/managedClusters")[0]
        tier = cluster["sku"]["tier"]
        cost = cluster["properties"]["metricsProfile"]["costAnalysis"]["enabled"]
        # Cost analysis is rejected on the Free tier, so both must switch on the same condition.
        condition = "equals(parameters('env'), 'prod')"
        self.assertIn(condition, tier)
        self.assertIn(condition, cost)

    def test_service_health_reaches_the_action_group(self):
        alert = of_type("Microsoft.Insights/activityLogAlerts")[0]
        props = alert["properties"]
        self.assertEqual(props["scopes"], ["[subscription().id]"])
        conditions = props["condition"]["allOf"]
        self.assertIn({"field": "category", "equals": "ServiceHealth"}, conditions)
        fields = {c.get("field") for c in conditions}
        # Without a region filter every Azure incident worldwide would alert.
        self.assertIn("properties.impactedServices[*].ImpactedRegions[*].RegionName", fields)
        self.assertTrue(props["actions"]["actionGroups"])

    def test_budget_alerts_on_actual_and_forecast(self):
        budget = of_type("Microsoft.Consumption/budgets")[0]
        notes = budget["properties"]["notifications"]
        kinds = {n["thresholdType"] for n in notes.values()}
        self.assertEqual(kinds, {"Actual", "Forecasted"})
        for note in notes.values():
            self.assertTrue(note["contactGroups"], "budget alerts must reach the action group")

    def prometheus_rules(self):
        groups = of_type("Microsoft.AlertsManagement/prometheusRuleGroups")
        return [rule for g in groups for rule in g["properties"]["rules"]]

    def test_prometheus_alerts_route_and_resolve(self):
        rules = self.prometheus_rules()
        self.assertGreaterEqual(len(rules), 6)
        for rule in rules:
            name = rule["alert"]
            self.assertTrue(rule["for"].startswith("PT"), name)
            self.assertIn(rule["severity"], range(0, 5), name)
            self.assertTrue(rule["actions"], f"{name} has no action group")
            self.assertIs(rule["resolveConfiguration"]["autoResolved"], True, name)
            self.assertIn("description", rule["annotations"], name)

    @unittest.skipUnless(shutil.which("promtool"), "promtool not installed")
    def test_prometheus_expressions_parse(self):
        # Azure only rejects a bad expression at deploy time; promtool catches it here.
        groups = {"groups": [{"name": "platform", "rules": [
            {"alert": r["alert"], "expr": r["expression"]} for r in self.prometheus_rules()
        ]}]}
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
            json.dump(groups, handle)  # JSON is valid YAML
        result = subprocess.run(["promtool", "check", "rules", handle.name], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_no_secure_outputs_or_keys_in_outputs(self):
        with open(TEMPLATE_PATH, encoding="utf-8") as handle:
            text = handle.read()
        for needle in ("listKeys(", "listCredentials(", "listAdminCredentials("):
            self.assertNotIn(needle, text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
