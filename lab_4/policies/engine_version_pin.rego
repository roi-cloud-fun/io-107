# IO-107 Lab 4 — engine_version_pin.rego
#
# OPA / Conftest policy. DENIES any `aws_rds_cluster` whose `engine_version`
# is not in the platform team's approved list. This is the same lifecycle
# pattern Module 6 teaches: pin the allowed versions in policy, raise a PR
# to widen the list when the platform team certifies a new version, never
# weaken the policy to make a failing plan pass.
#
# Evaluated against the JSON output of `terraform show -json tfplan`, i.e.
# the `resource_changes` array of the Terraform plan.
#
# Sources:
#   https://www.openpolicyagent.org/docs/latest/policy-language/
#   https://www.conftest.dev/
#   https://developer.hashicorp.com/terraform/internals/json-format

package main

# Versions the platform team has certified for the training environment.
# Update by PR + platform approval — NOT by editing this file directly in a lab.
approved_engine_versions := {"16.13", "16.14"}

# Walk every resource_change in the plan and find the `terraform_data`
# observability shim that surfaces the target engine version (see
# aurora_cluster.tf — the cluster's own engine_version is hidden from the
# plan by `lifecycle.ignore_changes`, so the policy reads the marker).
deny[msg] {
    rc := input.resource_changes[_]
    rc.type == "terraform_data"
    rc.name == "engine_version_target"
    is_managed_change(rc.change.actions)
    engine_version := rc.change.after.input
    not approved_engine_versions[engine_version]
    msg := sprintf(
        "target_engine_version '%s' is not in the approved list %v. Bump to an approved version or raise a platform PR to update the policy.",
        [engine_version, approved_engine_versions],
    )
}

# Treat create and update as managed changes that must satisfy the pin.
# A pure "no-op" or "delete" action set is not gated by this rule.
is_managed_change(actions) {
    actions[_] == "create"
}

is_managed_change(actions) {
    actions[_] == "update"
}
