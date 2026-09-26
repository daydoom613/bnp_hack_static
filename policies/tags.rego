# Tag Enforcement: every resource carries Owner, Project, Environment, Cost_Center.
# Shares package finops (and its helpers) with budget.rego.
package finops

import rego.v1

mandatory_tags := {"Owner", "Project", "Environment", "Cost_Center"}

# Taggable resources expose tags_all. If it is only known after apply, it is
# built from provider default_tags, which were already checked at plan time.
deny contains msg if {
	some rc in live_changes
	"tags_all" in object.keys(rc.change.after)
	not rc.change.after_unknown.tags_all
	some key in mandatory_tags
	not has_value(resource_tags(rc), key)
	msg := sprintf("%s: missing mandatory tag %q", [rc.address, key])
}

# ASGs ignore default_tags. Their instances are only tagged if the ASG
# propagates each mandatory tag at launch.
deny contains msg if {
	some rc in live_changes
	rc.type == "aws_autoscaling_group"
	some key in mandatory_tags
	not asg_propagates(rc, key)
	msg := sprintf("%s: mandatory tag %q is not propagated to launched instances", [rc.address, key])
}

has_value(tags, key) if {
	is_string(tags[key])
	trim_space(tags[key]) != ""
}

asg_propagates(rc, key) if {
	some t in rc.change.after.tag
	t.key == key
	t.propagate_at_launch == true
	trim_space(t.value) != ""
}
