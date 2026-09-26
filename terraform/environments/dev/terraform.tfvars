# Dynamic (deployed) stack. NO budget_cap here: it comes from data/budget_cap.txt (TF_VAR_budget_cap).

aws_region     = "eu-west-1"
aws_account_id = "073639462496"

project     = "finops-cloudscale"
owner       = "pranav6657@gmail.com"
environment = "dev"
cost_center = "1001"

# Web: On-Demand t3.small, 1..4. Worker: t3.micro 70% On-Demand / 30% Spot, 1..4.
web_instance_type    = "t3.small"
web_min_size         = 1
web_max_size         = 4
worker_instance_type = "t3.micro"
worker_min_size      = 1
worker_max_size      = 4

# Tag pushed to ECR by deploy.yml or scripts/build_and_push.sh. Tags are immutable: bump to ship a new app.
image_tag = "v1"

# This account cannot use AWS FIS ("needs a subscription for the service": AWS free-plan
# accounts block it). chaos/spot_interruption.sh then terminates the Spot worker via Auto Scaling.
enable_fis = false

# Optional: e-mail for the 90%-of-budget alarm (confirm the SNS subscription e-mail).
# alert_email = "pranav6657@gmail.com"
