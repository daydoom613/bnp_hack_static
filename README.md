# FinOps CloudScale: Dynamic CloudScale Cost Optimizer

A SaaS API that scales its own compute with demand, puts non-critical work on Spot,
never lets critical requests touch Spot, and blocks any change whose projected monthly
cost would exceed the budget cap. Everything is Terraform, guarded by OPA, deployed by
GitHub Actions, watched in Grafana and chaos-tested with AWS FIS and `tc`.

## The numbers (budget cap = our $120 AWS credit)

| | Fleet | Monthly compute cost | OPA vs cap 120 |
|---|---|---:|---|
| **Static baseline** (calculated, never deployed) | 6 × t3.small On-Demand, 24×7 | **91.10** | 75.9%, allowed |
| **Dynamic stack, worst case** (every ASG at max) | 4 × t3.small web + 4 × t3.micro worker (3 On-Demand + 1 Spot) | 85.85 | 71.5%, allowed |
| Dynamic stack, Reserved-Instance pricing | same | 47.30 | the "cheaper RI" test |
| **Dynamic stack, measured** | whatever the ASGs actually ran during the load test | *from `scripts/run_load_test.sh`* | written to `cost_savings.csv` |

All figures use `data/pricing_matrix.csv` × 730 h. Only EC2 compute is counted: ALB, NAT and RDS
are identical in both stacks and cancel out of the avoided cost.

**Why the static stack is never deployed.** A fixed fleet's cost is fully determined by its plan.
`terraform/environments/baseline` is planned and priced by the same `finops/cost_model.py` and OPA
guard as the real stack (6 × 0.0208 × 730 = 91.10), and deploying it would only spend credit to
confirm that number. The baseline is sized to the dynamic stack's peak compute: 4 × t3.small +
4 × t3.micro is the same money as 6 × t3.small. That is what you run when nothing scales.

**Why we don't wait 30 days.** A Lambda prices every running instance every minute
(`FinOps/Cost HourlyCost`, at On-Demand or Spot rates by the instance's real market). A load test
replays a compressed day of traffic. The time-weighted average × 730 h is the optimized monthly
cost, and `cost_report.py` turns it into `cost_savings.csv`.

## Architecture

```
                         ┌──────────────────────── VPC 10.0.0.0/16 (2 AZ) ───────────────────────────┐
 traffic_sim.py ──HTTP──▶│ ALB ──(default, X-Critical=true)──▶ Web ASG  t3.small On-Demand  1..4       │
 (CSV profile)           │   │                                  CPU≈50% target tracking,              │
                         │   │                                  RequestCountPerTarget + CPU>70% steps │
                         │   └──(X-Target-Tier: worker, tests)─▶ Worker ASG t3.micro 70% OD / 30% Spot │
                         │                                      capacity-optimized, 1..4,             │
                         │   Web hosts ──non-critical jobs──▶ SQS ──▶ workers (step scaling on        │
                         │                                            queue_length > 50)              │
                         │   both tiers ──▶ RDS Postgres 16 (password in Secrets Manager, rotated)    │
                         └────────────────────────────────────────────────────────────────────────────┘
  Lambda metrics_publisher (every minute): queue_length + live cost metrics → CloudWatch → Grafana
  Lambda spot_drain: termination lifecycle hook / Spot 2-min notice → deregister, docker stop, CONTINUE
  AWS FIS: Spot interruption  ·  SSM + tc netem: latency/loss on the ALB path  ·  CloudWatch alarm: budget ≥ 90%
  Terraform state: S3 (KMS CMK, versioned, TLS-only) + DynamoDB lock  ·  mandatory tags via default_tags
```

- **Critical traffic never runs on Spot.** It goes three layers deep:
  1. The simulator sets `X-Critical` from `service_priority.xlsx`.
  2. An ALB rule sends `X-Critical: true` to the On-Demand web tier.
  3. The app itself answers **503** to any critical request that reaches a Spot host. Request types missing from the sheet count as critical.
- **Non-critical work prefers Spot.** Web hosts answer quickly and queue the heavy part. Workers, 30% of them Spot, drain the queue.

## Repository layout

| Path | What |
|---|---|
| `app/` | The API: FastAPI + Postgres, CRUD, `/health`, `/metrics`, Spot guard, SQS consumer. One image, `ROLE=web` or `worker`. |
| `lambdas/` | `metrics_publisher` (queue_length + cost metrics), `spot_drain` (lifecycle hook). |
| `terraform/backend.tf` | One-time bootstrap: state bucket + KMS + lock table, ECR, GitHub OIDC role, **AWS Budget on the $120 credit**. |
| `terraform/environments/dev/` | **The deployed dynamic stack.** |
| `terraform/environments/baseline/` | The static baseline. **Plan only.** |
| `terraform/modules/` | network, alb, compute (ASG, mixed instances, lifecycle hook), rds, iam, storage, queue, scaling, functions, chaos. |
| `policies/` | OPA/Rego budget guard + tag rule, with `opa test` cases in `policies/tests/`. |
| `finops/` | `cost_model.py` (plan → projected cost), `optimized_cost.py` (measured cost), `cost_report.py` (→ `cost_savings.csv`). |
| `finops-app/` | Traffic simulator (`simulator/traffic_sim.py`), profiles in `finops-app/data/`. |
| `scripts/` | Build/push, plan + guard, load test, Spot-guard test, queue-spike test, budget-alert demo. |
| `chaos/` | Spot interruption (FIS), latency injection (tc), scale-in under load, evidence collection. |
| `observability/` | Grafana (docker compose) with the CloudWatch datasource and the FinOps dashboard JSON. |
| `data/` | The challenge inputs. `budget_cap.txt` = 120, `baseline_cost.json` = 91.10. |
| `.github/workflows/deploy.yml` | validate → quick traffic sim → image → plan + OPA → apply → smoke + sim → S3. |

---

## Runbook

Commands are for **Git Bash** on Windows (or any bash). Account `073639462496`, region `eu-west-1`.

### 0. One-time setup on your machine

```bash
winget install Hashicorp.Terraform Amazon.AWSCLI
# OPA: ~/bin/opa.exe on this machine is a truncated download (6 MB, won't start). Replace it:
curl -L -o ~/bin/opa.exe https://openpolicyagent.org/downloads/v0.70.0/opa_windows_amd64.exe
aws configure --profile finops        # access key of an admin/power user in the account
export AWS_PROFILE=finops
pip install -r finops-app/requirements.txt -r app/requirements-dev.txt
```

- **Docker Desktop must be running.** It builds the image and runs Grafana.
- **Check EC2 quotas.** A new account can have a very low vCPU quota. Peak is 8 instances × 2 vCPU = 16 vCPU.
  ```bash
  aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A --query Quota.Value   # On-Demand standard, need >= 16
  aws service-quotas get-service-quota --service-code ec2 --quota-code L-34B43A08 --query Quota.Value   # Spot standard, need >= 2
  ```

### 1. Test locally first (free)

```bash
pytest -q app/tests                    # API + Spot guard unit tests
opa test policies -v                   # 14 budget/tag policy tests
docker compose up --build -d           # app :8080 (On-Demand), "Spot" app :8081, Postgres
curl -X POST localhost:8081/process -H 'Content-Type: application/json' -d '{"request_type":"CreateOrder"}'   # -> 503
docker compose down
```

### 2. Bootstrap the account (once)

```bash
terraform -chdir=terraform init
terraform -chdir=terraform apply -var aws_account_id=073639462496 -var owner=pranav6657@gmail.com \
  -var cost_center=1001 -var github_repo=daydoom613/bnp_hack_static
terraform -chdir=terraform output -raw backend_hcl > terraform/environments/dev/backend.hcl
```

This creates the state backend, ECR, the CI role and an **AWS Budget that e-mails you at 50/80/100% of $120**. Confirm the subscription e-mail.

### 3. Push the app image

```bash
scripts/build_and_push.sh v1
```

### 4. Plan both stacks through the budget guard

```bash
scripts/plan_and_check.sh baseline     # static: 91.10 / 120 -> allow = true   (never apply it)
scripts/plan_and_check.sh dev          # dynamic: 85.85 / 120 -> allow = true
terraform -chdir=terraform/environments/dev apply tfplan
curl "$(terraform -chdir=terraform/environments/dev output -raw health_url)"    # 200 after ~3-5 min
```

### 5. Open the dashboard

```bash
docker compose -f observability/docker-compose.yml up -d   # http://localhost:3000/d/finops-cloudscale
```

It shows live web/worker/Spot counts, projected vs baseline cost, avoided cost, queue length, CPU, latency and 5xx. The **Budget used** panel turns **red at ≥ 90%** of the cap.

### 6. Measure the savings

Run this from **AWS CloudShell** in eu-west-1 so latency is measured in-region: clone the repo and `pip install -r finops-app/requirements.txt`. It also works from your laptop.

```bash
scripts/run_load_test.sh                                          # 75-min profile (default)
scripts/run_load_test.sh finops-app/data/traffic_profiles.csv     # the Dataset document's 4.7 h profile
```

The result lands in `reports/load-<ts>/cost_savings.csv`: baseline, optimized (measured), avoided, % savings and budget use. It is also uploaded to `s3://<artifacts>/reports/`.

### 7. Run the tests and chaos experiments (see the test catalogue below)

### 8. Tear down when you stop working

```bash
TF_VAR_budget_cap=120 terraform -chdir=terraform/environments/dev destroy
```

Or use **Actions → deploy → Run workflow → destroy**. The evidence bucket and the bootstrap stay.

### CI/CD (after step 2)

1. Push the repo to GitHub.
2. Add the secret `AWS_ROLE_ARN`: `terraform -chdir=terraform output -raw ci_role_arn`.
3. Protect `main`.

After that:
- **Pull requests** get validate → quick traffic sim → plan + OPA for both stacks, plus a PR comment.
- **Merges to `main`** also apply the exact approved plan, smoke-test `/health`, run a short simulation against the ALB and store `traffic_report.csv` in S3.
- **Once CI works, only CI applies.**

---

## What the $120 credit buys

Approximate eu-west-1 list prices. This is real AWS spend, not the pricing-matrix model.

| State | $/hour | $/day | Notes |
|---|---:|---:|---|
| Stack up, idle (1 web + 1 worker) | ~0.17 | ~4.0 | NAT 0.048, ALB ~0.03, RDS ~0.02, 2 instances ~0.035, public IPv4 0.015, EBS/CloudWatch ~0.02 |
| Under peak load (4 web + 4 worker) | ~0.35 | n/a | Plus t3 "unlimited" CPU credits (~$0.03/instance-hour at 50% CPU) |
| Stack destroyed | ~0.002 | ~0.05 | State bucket, KMS key, ECR, artifacts |

A realistic hackathon comes to about $10. That covers roughly 30 h of stack uptime, a few 75-min load tests, one 4.7 h run, the chaos tests (FIS about $0.10 per action-minute) and a demo day. **Leaving the stack up 24×7 burns about $120/month, which is the whole credit, so destroy it between sessions.** The AWS Budget from step 2 warns you before that happens.

---

## Definition of Done: where each item is

| # | Item | How it is met |
|---|---|---|
| 1 | Terraform full stack | `terraform/`: VPC, ALB, On-Demand Web ASG, Spot-enabled Worker ASG, RDS, SQS, Lambdas, FIS, encrypted remote state (S3 + KMS CMK + DynamoDB lock), IAM roles, mandatory tags via `default_tags` and ASG propagation. ECS/API Gateway were examples; the API runs on EC2 as item 2 requires. |
| 2 | EC2 REST API on RDS via ALB, CRUD + `/metrics` | `app/`: `/items` CRUD, `/orders`, `/catalog`, `/process`, `/health`, Prometheus `/metrics`. |
| 3 | Python traffic simulator, CSV profile → `traffic_report.csv` in S3 | `finops-app/simulator/traffic_sim.py` (httpx async). `run_load_test.sh` and CI upload to `s3://<artifacts>/reports/`. |
| 4 | CPU ≈ 50% + RequestCount scaling, Web 1 → ≥ 4 and back | `modules/scaling`: target tracking at 50%, step scaling on ALB `RequestCountPerTarget` and CPU > 70% × 2. Target tracking scales in after the lull. |
| 5 | Worker 70/30 mixed, capacity-optimized, lifecycle drain | `modules/compute` (mixed policy, capacity rebalance, termination hook) + `lambdas/spot_drain`. The app also watches the 2-min Spot notice itself. |
| 6 | OPA blocks over-budget / untagged plans | `policies/budget.rego`, `tags.rego`, 14 tests. The cost comes from `cost_model.py` (Infracost-shaped JSON). Raw Infracost JSON is accepted too, and Infracost runs in CI when `INFRACOST_API_KEY` is set. |
| 7 | CI: fmt/validate, OPA, quick sim, then apply | `.github/workflows/deploy.yml` |
| 8 | Grafana: instances, projected cost, avoided cost, red ≥ 90% | `observability/`. The dashboard JSON is importable. There is also a CloudWatch alarm `<stack>-budget-90pct`. |
| 9 | Chaos: Spot termination + latency, logs/video | `chaos/spot_interruption.sh` (FIS), `chaos/latency_injection.sh` (tc netem), `chaos/scale_in_test.sh`. Evidence goes to S3. Screen-record Grafana while they run. |
| 10 | `cost_savings.csv` | `finops/cost_report.py` via `scripts/run_load_test.sh` |

## Test catalogue (the problem statement's tables)

| Test | Command | Expected |
|---|---|---|
| Deploy the stack | step 4 or CI | apply succeeds |
| `/health` 200 within 100 ms | `curl -w '%{time_total}' $(... output -raw health_url)` from CloudShell | 200, no DB access |
| 50 RPS for 5 min | `MAX_ERROR_RATE=5 MAX_AVG_LATENCY_MS=200 scripts/run_load_test.sh finops-app/data/traffic_profile_constant.csv` | ≤ 5% errors, avg < 200 ms (exit code 0) |
| Web scales to ≥ 2 at CPU > 70% | the peak of any load test | `web_scaling_activities.json` / Grafana |
| OPA passes a baseline plan | `scripts/plan_and_check.sh baseline` | `allow = true` |
| CI green | push to `main` | all jobs pass |
| Full profile, Web ≤ 8, Spot workers at queue > 50 | `scripts/run_load_test.sh finops-app/data/traffic_profiles.csv` | web 1 → 4, workers scale on queue_length |
| 30% critical, never on Spot | `scripts/test_spot_guard.sh`, plus every load test (`CRITICAL_SHARE=0.3`) | Spot hosts → 503. `critical_on_spot = 0` in `traffic_report.csv` |
| Cheaper RI + new cap → OPA blocks | `echo 80 > cap80.txt; BUDGET_CAP_FILE=cap80.txt scripts/plan_and_check.sh dev` → blocked; add `ON_DEMAND_RATE=reserved` → 47.30, allowed | `allow = false`, "projected monthly cost 85.85 exceeds budget_cap 80" |
| queue_length spike 120 → +1 worker | `scripts/test_queue_spike.sh` | desired capacity +1 |
| Spot termination (FIS) | `chaos/spot_interruption.sh` | drained, replaced < 2 min, no 5xx |
| +200 ms / 5% loss for 60 s | `chaos/latency_injection.sh` (run from CloudShell) | increase ≤ 300 ms, errors ≤ 2% |
| Scale-in under load | `chaos/scale_in_test.sh` | targets drain, API stays healthy |
| Evidence to S3 | every script uploads; `chaos/collect_evidence.sh 60` for ad-hoc windows | `s3://<artifacts>/evidence/` |
| Red budget alert | `scripts/budget_alert_demo.sh 25`, then `scripts/budget_alert_demo.sh reset` | Grafana panel red, alarm ALARM |

## Contract between the pieces

- **API.**
  - Port 8080. `GET /health` answers 200 without touching the DB, and 503 while draining.
  - Business endpoints:
    - `POST /orders` (CreateOrder, critical)
    - `GET /items`, `GET /catalog` (GetCatalog)
    - `PUT /items/{id}` (UpdateItem, critical)
    - `POST /items`, `DELETE /items/{id}` (not in the sheet, so critical)
    - `POST /process` for the simulator, with body `{"request_type", "critical"}` and headers `X-Request-Type` / `X-Critical`.
  - Every response carries `X-Instance-Id`, `X-Instance-Lifecycle` and `X-Role`.
- **Container env.** Set by `scripts/user_data.sh`:
  - `ROLE`, `DB_HOST`, `DB_NAME`, `DB_SECRET_ARN`, `QUEUE_URL`, `AWS_REGION`
  - `CRITICAL_WORK_MS`, `NONCRITICAL_WORK_MS`, `JOB_WORK_MS`: simulated CPU per request/job, so CPU follows load.
- **Metrics.**
  - Prometheus: `http_requests_total{type,critical,status}`, `http_request_duration_seconds`, `spot_rejections_total`, `jobs_*`.
  - CloudWatch `FinOps/App`: `queue_length{QueueName}`.
  - CloudWatch `FinOps/Cost`: `HourlyCost`, `ProjectedMonthlyCost`, `BaselineMonthlyCost`, `AvoidedMonthlyCost`, `SavingsPercent`, `BudgetCap`, `BudgetUsagePercent` (all `{Stack}`), and `InstanceCount{Stack,Tier,Market}`.
- **Secrets.** RDS generates the DB password and keeps it in Secrets Manager. The app reads it at runtime and re-reads it after rotation. There are no credentials in the repo, env or state.

## Decisions and known limits

- **Budget cap = 120**, our real credit. `budget_cap` has no default and is never in code: `data/budget_cap.txt` → `TF_VAR_budget_cap` → the plan → OPA.
- **Projected cost uses ASG `max_size`**, the most a plan could ever run. The measured optimized cost uses what actually ran.
- **Cost scope is EC2 compute**, the same on both sides. The pricing matrix has no ALB/NAT/RDS rates, and those are identical in both stacks. For the full bill, set `INFRACOST_API_KEY` and Infracost runs next to the model in CI.
- **Spot appears at 4 workers.** AWS rounds the On-Demand share of a 70/30 split up: 1–3 workers are all On-Demand, and 4 gives 3 + 1 Spot. The test scripts raise the worker ASG to 4 when they need a Spot host.
- **Latency chaos targets the ALB path.** netem applies only to packets bound for the ALB's subnets, so DB and SQS round trips aren't counted twice. That matches "on the ALB" in the problem statement.
- **Latency is measured from wherever the simulator runs.** From India, the round trip to eu-west-1 alone is about 150–200 ms. Use CloudShell for the 300 ms tests, and compare the before/during *increase*, which is what the latency script reports.
- **Forced scale-in** sets the Web ASG's desired capacity straight to its minimum under load. Moving an alarm threshold would scale out, not in.
- **Budget alert demo.** `budget_alert_demo.sh` changes only the SSM parameter the live metrics read. OPA still uses `data/budget_cap.txt`, and the next apply restores the parameter.
- **HTTP only.** An ALB DNS name can't get a public certificate without a domain. Set `certificate_arn` to get HTTPS.
- **The FastAPI dashboard in `finops-app/dashboard` is the earlier local prototype.** Grafana is the dashboard of record.
