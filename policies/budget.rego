# Budget Guard (problem statement): projected monthly spend <= budget_cap,
# allowed instance types, and a mixed-instances policy where Spot is expected.
# Tag enforcement lives in tags.rego (same package).
#
#   opa eval -d policies -i opa_input.json "data.finops.allow"    -> true / false
#   opa eval -d policies -i opa_input.json "data.finops.deny"     -> why it failed
#
# Input: {"plan": <terraform show -json tfplan>, "cost": <finops/cost_model.py output>}
package finops

import rego.v1

default allow := false

allow if count(deny) == 0

# -----------------------------------------------------------------------------
# Projected cost vs budget_cap
# -----------------------------------------------------------------------------

# Read from the plan's variables, so it is the Terraform variable the plan was
# made with (set from data/budget_cap.txt via TF_VAR_budget_cap, never in code).
budget_cap := to_number(input.plan.variables.budget_cap.value)

# finops/cost_model.py output (baseline_cost.json shape), or raw Infracost JSON.
projected_monthly_cost := to_number(input.cost.TotalMonthlyCost) if {
	input.cost.TotalMonthlyCost != null
} else := to_number(input.cost.totalMonthlyCost) if {
	input.cost.totalMonthlyCost != null
}

deny contains "budget_cap is not set in the plan: export TF_VAR_budget_cap from data/budget_cap.txt" if {
	not budget_cap
}

deny contains "no cost estimate in input.cost: run finops/cost_model.py on the plan" if {
	not projected_monthly_cost
}

deny contains msg if {
	projected_monthly_cost > budget_cap
	msg := sprintf("projected monthly cost %v exceeds budget_cap %v", [projected_monthly_cost, budget_cap])
}

deny contains msg if {
	some r in input.cost.UnpricedResources
	msg := sprintf("%s: instance type %s has no price in data/pricing_matrix.csv, so the plan cannot be shown to fit the budget", [r.Name, r.InstanceType])
}

# Same 90% threshold as the dashboard's red alert. Reported, does not block.
warn contains msg if {
	projected_monthly_cost <= budget_cap
	projected_monthly_cost >= 0.9 * budget_cap
	msg := sprintf("projected monthly cost %v is at or above 90%% of budget_cap %v", [projected_monthly_cost, budget_cap])
}

# -----------------------------------------------------------------------------
# Instance-type whitelist: web tier may only use t3.nano/micro/small/medium
# -----------------------------------------------------------------------------
allowed_web_instance_types := {"t3.nano", "t3.micro", "t3.small", "t3.medium"}

deny contains msg if {
	some rc in live_changes
	rc.type in {"aws_launch_template", "aws_instance"}
	tier(rc) == "web"
	itype := rc.change.after.instance_type
	is_string(itype)
	not itype in allowed_web_instance_types
	msg := sprintf("%s: instance type %q is not allowed for the web tier (allowed: %v)", [rc.address, itype, sort(allowed_web_instance_types)])
}

# Mixed-instances overrides on a web-tier ASG are held to the same list.
deny contains msg if {
	some rc in live_changes
	rc.type == "aws_autoscaling_group"
	asg_tier(rc) == "web"
	some mip in rc.change.after.mixed_instances_policy
	some spec in mip.launch_template
	some override in spec.override
	itype := override.instance_type
	is_string(itype)
	not itype in allowed_web_instance_types
	msg := sprintf("%s: override instance type %q is not allowed for the web tier (allowed: %v)", [rc.address, itype, sort(allowed_web_instance_types)])
}

# -----------------------------------------------------------------------------
# Mixed-instances policy: worker-tier ASGs must mix On-Demand and Spot.
# The static version has no worker tier (all web, all On-Demand), so this only
# applies once the dynamic stack adds an ASG tagged Tier=worker.
# -----------------------------------------------------------------------------
deny contains msg if {
	some rc in live_changes
	rc.type == "aws_autoscaling_group"
	asg_tier(rc) == "worker"
	count(object.get(rc.change.after, "mixed_instances_policy", [])) == 0
	msg := sprintf("%s: worker ASG must use a mixed-instances policy (On-Demand + Spot)", [rc.address])
}

deny contains msg if {
	some rc in live_changes
	rc.type == "aws_autoscaling_group"
	asg_tier(rc) == "worker"
	some mip in rc.change.after.mixed_instances_policy
	some dist in mip.instances_distribution
	dist.on_demand_percentage_above_base_capacity >= 100
	msg := sprintf("%s: mixed-instances policy has no Spot share (on_demand_percentage_above_base_capacity = 100)", [rc.address])
}

# Presence of a mixed-instances policy: a scaling (Stack=dynamic) plan must run its
# non-critical work on at least one Spot-enabled worker ASG. The static baseline
# (Stack=baseline) is all On-Demand by definition and is not held to this.
deny contains "the dynamic stack has no mixed-instances (On-Demand + Spot) worker ASG" if {
	some rc in live_changes
	rc.type == "aws_autoscaling_group"
	object.get(asg_tags(rc), "Stack", "") == "dynamic"
	count(spot_worker_asgs) == 0
}

spot_worker_asgs contains rc.address if {
	some rc in live_changes
	rc.type == "aws_autoscaling_group"
	asg_tier(rc) == "worker"
	count(object.get(rc.change.after, "mixed_instances_policy", [])) > 0
}

# -----------------------------------------------------------------------------
# Helpers shared with tags.rego
# -----------------------------------------------------------------------------

# Managed resources that still exist once the plan is applied.
live_changes contains rc if {
	some rc in input.plan.resource_changes
	rc.mode == "managed"
	rc.change.actions != ["delete"]
}

# tags_all already includes the provider's default_tags.
resource_tags(rc) := rc.change.after.tags_all if {
	is_object(rc.change.after.tags_all)
} else := rc.change.after.tags if {
	is_object(rc.change.after.tags)
} else := {}

# Missing Tier counts as web, so an untagged launch template is still checked.
tier(rc) := object.get(resource_tags(rc), "Tier", "web")

# ASGs use `tag` blocks instead of a tags map.
asg_tags(rc) := {t.key: t.value | some t in rc.change.after.tag}

asg_tier(rc) := object.get(asg_tags(rc), "Tier", "web")
