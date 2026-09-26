# opa test policies -v
# Pass and fail cases for the Budget Guard (budget.rego) and Tag Enforcement (tags.rego).
package finops_test

import rego.v1

import data.finops

mandatory := {"Owner": "owner@example.com", "Project": "finops-cloudscale", "Environment": "dev", "Cost_Center": "1001"}

propagated(tags) := [{"key": k, "value": v, "propagate_at_launch": true} | some k, v in tags]

launch_template(address, itype, tags) := {
	"address": address,
	"mode": "managed",
	"type": "aws_launch_template",
	"change": {"actions": ["create"], "after": {"instance_type": itype, "tags_all": tags}, "after_unknown": {}},
}

asg(address, tags, extra) := {
	"address": address,
	"mode": "managed",
	"type": "aws_autoscaling_group",
	"change": {
		"actions": ["create"],
		"after": object.union({"max_size": 4, "tag": propagated(tags), "mixed_instances_policy": []}, extra),
		"after_unknown": {},
	},
}

mixed(on_demand_pct) := {"mixed_instances_policy": [{
	"instances_distribution": [{"on_demand_percentage_above_base_capacity": on_demand_pct}],
	"launch_template": [{"override": [{"instance_type": "t3.micro"}]}],
}]}

web_tags := object.union(mandatory, {"Tier": "web"})

worker_tags := object.union(mandatory, {"Tier": "worker"})

web_lt := launch_template("module.web.aws_launch_template.this", "t3.small", web_tags)

web_asg := asg("module.web.aws_autoscaling_group.this", web_tags, {})

worker_lt := launch_template("module.worker.aws_launch_template.this", "t3.micro", worker_tags)

worker_asg := asg("module.worker.aws_autoscaling_group.this", worker_tags, mixed(70))

baseline_resources := [web_lt, web_asg]

dynamic_resources := [web_lt, web_asg, worker_lt, worker_asg]

input_for(resources, cap, cost) := {
	"plan": {"variables": {"budget_cap": {"value": cap}}, "resource_changes": resources},
	"cost": cost,
}

priced(total) := {"TotalMonthlyCost": total, "UnpricedResources": []}

# -----------------------------------------------------------------------------
# Happy path
# -----------------------------------------------------------------------------
test_baseline_plan_is_allowed if {
	finops.allow with input as input_for(baseline_resources, 120, priced(91.1))
}

test_dynamic_plan_is_allowed if {
	finops.allow with input as input_for(dynamic_resources, 120, priced(85.85))
}

test_reserved_pricing_fits_a_lower_cap if {
	finops.allow with input as input_for(dynamic_resources, 80, priced(47.3))
}

# -----------------------------------------------------------------------------
# Budget
# -----------------------------------------------------------------------------
test_over_budget_is_denied_with_a_clear_message if {
	denied := finops.deny with input as input_for(dynamic_resources, 80, priced(85.85))
	"projected monthly cost 85.85 exceeds budget_cap 80" in denied
}

test_over_budget_is_not_allowed if {
	not finops.allow with input as input_for(dynamic_resources, 80, priced(85.85))
}

test_raw_infracost_json_is_accepted if {
	denied := finops.deny with input as input_for(dynamic_resources, 120, {"totalMonthlyCost": "130.50"})
	"projected monthly cost 130.5 exceeds budget_cap 120" in denied
}

test_missing_budget_cap_is_denied if {
	denied := finops.deny with input as {"plan": {"resource_changes": dynamic_resources}, "cost": priced(10)}
	"budget_cap is not set in the plan: export TF_VAR_budget_cap from data/budget_cap.txt" in denied
}

test_unpriced_instance_type_is_denied if {
	cost := {"TotalMonthlyCost": 10, "UnpricedResources": [{"Name": "module.worker.aws_autoscaling_group.this", "InstanceType": "m7g.large"}]}
	denied := finops.deny with input as input_for(dynamic_resources, 120, cost)
	some msg in denied
	contains(msg, "m7g.large has no price")
}

test_warns_at_90_percent_but_allows if {
	warnings := finops.warn with input as input_for(dynamic_resources, 120, priced(110))
	count(warnings) == 1
	finops.allow with input as input_for(dynamic_resources, 120, priced(110))
}

# -----------------------------------------------------------------------------
# Instance-type whitelist (web tier) and mixed-instances policy (worker tier)
# -----------------------------------------------------------------------------
test_web_tier_rejects_non_t3_types if {
	big := launch_template("module.web.aws_launch_template.this", "m5.large", web_tags)
	denied := finops.deny with input as input_for([big, web_asg], 120, priced(50))
	some msg in denied
	contains(msg, "\"m5.large\" is not allowed for the web tier")
}

test_worker_needs_a_mixed_instances_policy if {
	plain := asg("module.worker.aws_autoscaling_group.this", worker_tags, {})
	denied := finops.deny with input as input_for([web_lt, web_asg, worker_lt, plain], 120, priced(50))
	"module.worker.aws_autoscaling_group.this: worker ASG must use a mixed-instances policy (On-Demand + Spot)" in denied
}

test_worker_needs_a_spot_share if {
	all_on_demand := asg("module.worker.aws_autoscaling_group.this", worker_tags, mixed(100))
	denied := finops.deny with input as input_for([web_lt, web_asg, worker_lt, all_on_demand], 120, priced(50))
	some msg in denied
	contains(msg, "has no Spot share")
}

# -----------------------------------------------------------------------------
# Mandatory tags
# -----------------------------------------------------------------------------
test_missing_mandatory_tag_is_denied if {
	untagged := launch_template("module.web.aws_launch_template.this", "t3.small", object.remove(web_tags, ["Cost_Center"]))
	denied := finops.deny with input as input_for([untagged, web_asg], 120, priced(50))
	"module.web.aws_launch_template.this: missing mandatory tag \"Cost_Center\"" in denied
}

test_asg_must_propagate_mandatory_tags if {
	not_propagated := asg("module.web.aws_autoscaling_group.this", object.remove(web_tags, ["Owner"]), {})
	denied := finops.deny with input as input_for([web_lt, not_propagated], 120, priced(50))
	"module.web.aws_autoscaling_group.this: mandatory tag \"Owner\" is not propagated to launched instances" in denied
}

# -----------------------------------------------------------------------------
# Presence of a mixed-instances policy (dynamic stack only)
# -----------------------------------------------------------------------------
dynamic_web_tags := object.union(web_tags, {"Stack": "dynamic"})

dynamic_worker_tags := object.union(worker_tags, {"Stack": "dynamic"})

test_dynamic_stack_needs_a_spot_worker if {
	web_only := asg("module.web.aws_autoscaling_group.this", dynamic_web_tags, {})
	denied := finops.deny with input as input_for([web_lt, web_only], 120, priced(60))
	"the dynamic stack has no mixed-instances (On-Demand + Spot) worker ASG" in denied
}

test_dynamic_stack_with_a_spot_worker_is_allowed if {
	web := asg("module.web.aws_autoscaling_group.this", dynamic_web_tags, {})
	worker := asg("module.worker.aws_autoscaling_group.this", dynamic_worker_tags, mixed(70))
	finops.allow with input as input_for([web_lt, web, worker_lt, worker], 120, priced(85.85))
}
