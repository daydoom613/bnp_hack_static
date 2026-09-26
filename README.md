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
| `finops/` | `cost_model.py` (plan → projected cost), `optimized_cost.py` (measured cost), `cost_report.py` (→ `cost_savings.csv`), `window_summary.py` (scaling/queue/latency over a test window), `validate_inputs.py` (the dataset files vs the Dataset Building Document). |
| `finops-app/` | Traffic simulator (`simulator/traffic_sim.py`), profiles in `finops-app/data/`. |
| `scripts/` | **`run_tests.sh` (every Basic + Advanced test case, PASS/FAIL)**, build/push, plan + guard, load test, Spot-guard test, queue-spike test, budget-alert demo. |
| `chaos/` | Spot interruption (FIS), latency injection (tc), scale-in under load, evidence collection. |
| `observability/` | Grafana (docker compose) with the CloudWatch datasource and the FinOps dashboard JSON. |
| `data/` | The challenge inputs: `budget_cap.txt` = 120, `baseline_cost.json` = 91.10, `pricing_matrix.csv`, `service_priority.xlsx`, `traffic_profiles.csv` (the Dataset document's profile), `security_baseline.docx`, plus `service_priority_30pct.xlsx` for the 30%-critical test. |
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
opa test policies -v                   # 16 budget/tag/mixed-instances policy tests
python finops/validate_inputs.py       # the 6 dataset inputs vs the Dataset Building Document
docker compose up --build -d --wait    # app :8080 (On-Demand), "Spot" app :8081, Postgres
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
AWS_PROFILE=finops docker compose -f observability/docker-compose.yml up -d
```

Or, on Windows without Docker (or where Docker containers can't reach the internet):

```powershell
powershell -File observability\grafana-windows.ps1 -Profile finops   # needs Grafana extracted to %USERPROFILE%\grafana\grafana-v11.3.0
```

Either way, open **http://localhost:3000/d/finops-cloudscale** (refreshes every 10 s; admin/admin to edit). It shows live web/worker/Spot counts, projected vs baseline cost, avoided cost, queue length, CPU, latency and 5xx. The **Budget used** panel turns **red at ≥ 90%** of the cap.

### Live demo (15 minutes, for presenting)

```bash
AWS_PROFILE=finops scripts/live_demo.sh
```

This replays a sharp profile: 1 min warm-up, 9 min at 200 RPS, then a 5-min lull. The load is generated **inside eu-west-1**: the real simulator runs in a container on a worker instance, sent over SSM. Responses come back in ~40 ms whatever your own internet is like (`FROM=here` generates the load locally instead). The terminal prints the fleet every 15 s while Grafana shows the same thing:
- **~1 min in:** the request-count alarm fires and web instances launch.
- **Peak:** the queue builds and workers scale out; the 4th worker is Spot.
- **After the lull:** both tiers scale back in within ~5 min.

### 6. Measure the savings

Run this from **AWS CloudShell** in eu-west-1 so latency is measured in-region: clone the repo and `pip install -r finops-app/requirements.txt`. It also works from your laptop.

```bash
scripts/run_load_test.sh                                          # 75-min profile (default)
scripts/run_load_test.sh data/traffic_profiles.csv     # the Dataset document's 4.7 h profile
```

The result lands in `reports/load-<ts>/cost_savings.csv`: baseline, optimized (measured), avoided, % savings and budget use. It is also uploaded to `s3://<artifacts>/reports/`.

### 7. Run every test case

```bash
scripts/run_tests.sh basic        # B1-B6, ~20 min
scripts/run_tests.sh advanced     # A1-A5, ~1.5 h (A1 replays the 75-min profile; FULL_PROFILE=1 for 4.7 h)
scripts/run_tests.sh B3 A4        # any subset
```

Each test prints PASS/FAIL with its evidence, and the run ends with a table. Everything also lands in `evidence/tests-<ts>/` and `s3://<artifacts>/evidence/`.

**Run it where latency is fair.** B3's "< 200 ms average" is measured wherever the simulator runs. From India, the round trip to eu-west-1 alone is about 150–200 ms, so use one of these:
- **CI (easiest):** Actions → deploy → Run workflow, `tests = advanced`. Every Basic and Advanced test runs unattended after the apply, and that run is itself Advanced test A5.
- **AWS CloudShell** in eu-west-1: clone the repo, install Terraform (`curl -sLo t.zip https://releases.hashicorp.com/terraform/1.16.2/terraform_1.16.2_linux_amd64.zip && unzip t.zip -d ~/bin`), then `pip install -r finops-app/requirements.txt`, `terraform -chdir=terraform/environments/dev init -backend-config=backend.hcl`, and `scripts/run_tests.sh all`.

Then the chaos experiments: `chaos/spot_interruption.sh`, `chaos/latency_injection.sh`, `chaos/scale_in_test.sh`.

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
- **Merges to `main`** also apply the exact approved plan, smoke-test `/health`, run a short simulation against the ALB, store `traffic_report.csv` in S3, and run the **Basic test cases** (B1–B6).
- **Actions → deploy → Run workflow → `tests = advanced`** runs Basic + Advanced (about 2 h) with no manual step.
- **Once CI works, only CI applies.** Don't add required reviewers to the `dev` environment: the pipeline must run end to end unattended.

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
| 4 | CPU ≈ 50% + RequestCount scaling, Web 1 → ≥ 4 and back | `modules/scaling`. Scale-out: CPU target tracking at 50%, step scaling on ALB `RequestCountPerTarget` > 40 RPS per instance, and CPU > 70% × 2 periods. Scale-out on request count reacts within 1 minute. Scale-in: `RequestCountPerTarget` < 20 RPS per instance for 5 min. That gives 50 RPS → 2 web instances, 80 → 3, 150+ → 4, and back to 1 after the lull. |
| 5 | Worker 70/30 mixed, capacity-optimized, lifecycle drain | `modules/compute` (mixed policy, capacity rebalance, termination hook) + `lambdas/spot_drain`. The app also watches the 2-min Spot notice itself. |
| 6 | OPA blocks over-budget / untagged plans | `policies/budget.rego`, `tags.rego`, 16 tests (budget, tags, t3 whitelist, a Spot-enabled mixed-instances worker required in the dynamic stack). The cost comes from `cost_model.py` (Infracost-shaped JSON). Raw Infracost JSON is accepted too, and Infracost runs in CI when `INFRACOST_API_KEY` is set. |
| 7 | CI: fmt/validate, OPA, quick sim, then apply | `.github/workflows/deploy.yml` |
| 8 | Grafana: instances, projected cost, avoided cost, red ≥ 90% | `observability/`. The dashboard JSON is importable. There is also a CloudWatch alarm `<stack>-budget-90pct`. |
| 9 | Chaos: Spot termination + latency, logs/video | `chaos/spot_interruption.sh` (FIS), `chaos/latency_injection.sh` (tc netem), `chaos/scale_in_test.sh`. Evidence goes to S3. Screen-record Grafana while they run. |
| 10 | `cost_savings.csv` | `finops/cost_report.py` via `scripts/run_load_test.sh` |

## Test catalogue (the problem statement's tables)

`scripts/run_tests.sh` runs every Basic and Advanced case with these exact pass criteria.

| ID | Test | How | Pass when |
|---|---|---|---|
| B1 | Deploy the Terraform stack | apply (step 4 or CI), then `run_tests.sh B1` | ALB active, RDS available, both ASGs InService, both Lambdas Active; tagged resources listed |
| B2 | `/health` 200 within 100 ms | curl from here, plus 11 curls from a web instance via SSM (in-region) | HTTP 200 and in-region median < 100 ms |
| B3 | 50 RPS for 5 min | simulator, `traffic_profile_constant.csv`, gate `MAX_ERROR_RATE=5 MAX_AVG_LATENCY_MS=200` | ≤ 5% errors, average < 200 ms, `traffic_report.csv` in S3 |
| B4 | Web ≥ 2 when CPU > 70% for two periods | web reset to 1, then 150 RPS of critical requests (`traffic_profile_cpu.csv`) | InService ≥ 2 with a launch activity; CPU max and `web-cpu-high` ALARM transitions recorded |
| B5 | OPA passes the baseline plan | `scripts/plan_and_check.sh baseline` | `allow = true` (91.10 ≤ 120) |
| B6 | CI green | latest completed deploy run (`gh`), or the running workflow in CI | conclusion `success` |
| A1 | Full profile: web ≤ 8 at peak, Spot workers when queue_length > 50 | `scripts/run_load_test.sh` (75 min; `FULL_PROFILE=1` = the Dataset document's 4.7 h) | 2 ≤ web max ≤ 8, queue_length max > 50, Spot workers max ≥ 1; `cost_savings.csv` written |
| A2 | 30% critical, never processed on Spot | A1's traffic uses `data/service_priority_30pct.xlsx` (weights 15/15/70), plus `scripts/test_spot_guard.sh` | critical share 25–35%, `critical_on_spot = 0`, Spot hosts → 503, On-Demand hosts → 200 |
| A3 | Cheaper RI option + new budget_cap → OPA blocks | re-plan dev with `budget_cap = 80`, then again with `ON_DEMAND_RATE=reserved` | On-Demand plan blocked: "projected monthly cost 85.85 exceeds budget_cap 80"; RI-priced plan (47.30) allowed |
| A4 | queue_length spike to 120 → a Spot worker | `scripts/test_queue_spike.sh`: workers at 3 (all On-Demand), then publish 120 | desired capacity +1 (3 → 4) and a Spot worker is running |
| A5 | Full CI pipeline with the advanced load, unattended | deploy workflow with `tests = advanced` | that run's conclusion `success` |

Expert (chaos) tests have their own scripts, and each uploads its evidence to `s3://<artifacts>/evidence/`:

| Test | Command | Expected |
|---|---|---|
| Spot termination (FIS) | `chaos/spot_interruption.sh` | drained, replaced < 2 min, no 5xx |
| +200 ms / 5% loss for 60 s | `chaos/latency_injection.sh` (run from CloudShell) | increase ≤ 300 ms, errors ≤ 2% |
| Scale-in under load | `chaos/scale_in_test.sh` | targets drain, API stays healthy |
| Evidence for a window | `chaos/collect_evidence.sh 60` | logs, activities, alarms in S3 |
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
- **Scale-in alarms re-fire every minute.** While traffic or the queue is quiet they stay in ALARM, and CloudWatch re-runs Auto Scaling actions every minute. Tests that grow a fleet on purpose pause those alarm actions (`hold_scale_in` in `scripts/lib.sh`) and restore them on exit.
- **CPU target tracking only scales out.** Scale-in is request-based. With both scaling in, the peak fleet would flap between request-sized and CPU-sized.
- **Latency chaos targets the ALB path.** netem applies only to packets bound for the ALB's subnets, so DB and SQS round trips aren't counted twice. That matches "on the ALB" in the problem statement.
- **Latency is measured from wherever the simulator runs.** From India, the round trip to eu-west-1 alone is about 150–200 ms. Use CloudShell for the 300 ms tests, and compare the before/during *increase*, which is what the latency script reports.
- **Forced scale-in** sets the Web ASG's desired capacity straight to its minimum under load. Moving an alarm threshold would scale out, not in.
- **Budget alert demo.** `budget_alert_demo.sh` changes only the SSM parameter the live metrics read. OPA still uses `data/budget_cap.txt`, and the next apply restores the parameter.
- **HTTP only.** An ALB DNS name can't get a public certificate without a domain. Set `certificate_arn` to get HTTPS.
- **The FastAPI dashboard in `finops-app/dashboard` is the earlier local prototype.** Grafana is the dashboard of record.
