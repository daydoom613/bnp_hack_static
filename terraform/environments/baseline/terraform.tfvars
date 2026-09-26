# Static baseline: PLAN ONLY (scripts/plan_and_check.sh baseline). Never apply this folder.
# NO budget_cap here: it comes from data/budget_cap.txt (TF_VAR_budget_cap).

aws_region     = "eu-west-1"
aws_account_id = "073639462496"

project     = "finops-cloudscale"
owner       = "pranav6657@gmail.com"
environment = "dev"
cost_center = "1001"

# 6 x t3.small On-Demand 24x7 = the dynamic stack's peak compute, provisioned permanently.
instance_type  = "t3.small"
instance_count = 6
