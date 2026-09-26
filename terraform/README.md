# terraform/

The runbook, cost model and test catalogue are in the [root README](../README.md). This page maps the code.

| Path | What it is |
|---|---|
| `backend.tf` | One-time bootstrap, applied by hand with local state: S3 state bucket (KMS CMK, versioned, TLS-only), DynamoDB lock table, ECR repo, GitHub OIDC role for CI, AWS Budget alerts on the account credit. |
| `environments/dev/` | **The deployed dynamic stack.** Remote state `dev/terraform.tfstate`; `backend.hcl` comes from `terraform output -raw backend_hcl`. |
| `environments/baseline/` | **The static baseline, plan only** (local state). 6 × t3.small On-Demand, fixed. `scripts/plan_and_check.sh baseline` prices it (91.10) and runs OPA; never apply it. |
| `modules/network` | VPC, public / app / db subnets in 2 AZs, 1 NAT gateway, ALB → app → db security groups. |
| `modules/alb` | ALB (access logs on), web and worker target groups, HTTP listener (optional HTTPS), rules: `X-Critical: true` → web, `X-Target-Tier: worker` → worker (Spot-guard test hook). |
| `modules/compute` | Launch template (AL2023, IMDSv2 with hop limit 2, encrypted gp3) + ASG. Optional mixed On-Demand/Spot policy, capacity rebalance and termination lifecycle hook. Ignores `desired_capacity` after creation so scaling policies own it. |
| `modules/scaling` | Web: scale out on CPU target tracking at 50% (scale-in disabled), `RequestCountPerTarget` > 40 RPS/instance (1 min) and CPU > 70% × 2; scale in when `RequestCountPerTarget` < 20 RPS/instance for 5 min. Worker: step scaling on `FinOps/App queue_length` (> 50 out, < 5 for 5 min in). |
| `modules/queue` | SQS job queue + dead-letter queue. |
| `modules/functions` | `metrics_publisher` Lambda (every minute), `spot_drain` Lambda (lifecycle hook + Spot warning), `budget_cap` SSM parameter, ≥ 90% budget alarm. |
| `modules/chaos` | FIS Spot-interruption template, SSM `tc netem` document with automatic revert. |
| `modules/rds` | Postgres 16; RDS generates and rotates the password in Secrets Manager. |
| `modules/iam` | Instance role: the security_baseline policy, the DB secret, the job queue, container logs, SSM Session Manager (no SSH). |
| `modules/storage` | Artifacts bucket (evidence, reports) and ALB access-log bucket. |

## Guardrails the code enforces

- **`budget_cap` has no default and is in no `.tfvars`.** It only comes from `data/budget_cap.txt` via `TF_VAR_budget_cap`.
- **Mandatory tags on every resource.** `Owner`, `Project`, `Environment` and `Cost_Center` come from provider `default_tags`, and ASGs propagate them to instances explicitly. `policies/tags.rego` checks both.
- **Web tier types are limited to `t3.nano|micro|small|medium`.** A variable validation checks this, and so does `policies/budget.rego`.
- **Worker tiers need a Spot share.** `policies/budget.rego` requires a mixed-instances policy with Spot on any worker-tier ASG.
- **No credentials anywhere.** The DB password lives only in Secrets Manager, and CI uses OIDC.

## MFA-Delete on the state bucket

AWS only lets the **root user** with an MFA code turn this on, so Terraform can't:

```bash
aws s3api put-bucket-versioning --bucket <state_bucket output> \
  --versioning-configuration Status=Enabled,MFADelete=Enabled \
  --mfa "arn:aws:iam::<account-id>:mfa/root-account-mfa-device <code>"
```

Then re-apply `backend.tf` with `-var mfa_delete_enabled=true` so Terraform stops reporting drift.

## Destroy notes

- **The artifacts bucket survives `destroy`** unless it is empty or `artifacts_force_destroy = true` was applied first. It holds the evidence.
- **The bootstrap resources stay.** The state bucket has `prevent_destroy`.
- **Worker instances can take up to 3 minutes to go away** because of the termination lifecycle hook.
