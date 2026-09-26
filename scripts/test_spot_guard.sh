#!/usr/bin/env bash
# Advanced test: Critical requests are never processed on Spot hosts.
#
#   1. Critical payloads sent to the WORKER pool on purpose (header X-Target-Tier: worker):
#      Spot workers must answer 503, On-Demand workers process them (200).
#   2. The same payloads sent normally: the ALB routes X-Critical=true to the On-Demand
#      web tier, so every one succeeds.
#
# Usage: AWS_PROFILE=<profile> scripts/test_spot_guard.sh
# Evidence: evidence/spot-guard-<timestamp>/ and s3://<artifacts>/evidence/
set -euo pipefail
source "$(dirname "$0")/lib.sh"

OUT="$ROOT/evidence/spot-guard-$(stamp)"
mkdir -p "$OUT"

ensure_spot_worker
log "Waiting for the Spot worker to pass ALB health checks..."
sleep 60

set +e
"$PY" - "$(out app_url)/process" "$OUT" <<'EOF'
import collections, csv, json, sys, time, urllib.error, urllib.request

url, out = sys.argv[1], sys.argv[2]
body = json.dumps({"request_type": "CreateOrder", "priority": 1, "critical": True}).encode()


def call(extra):
    headers = {"Content-Type": "application/json", "X-Critical": "true", "X-Request-Type": "CreateOrder", **extra}
    req = urllib.request.Request(url, data=body, method="POST", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, r.headers
    except urllib.error.HTTPError as e:
        return e.code, e.headers


rows, tally = [], collections.Counter()
spot_seen = 0
for i in range(300):  # until at least 10 answers came from a Spot host
    status, h = call({"X-Target-Tier": "worker"})
    life = h.get("X-Instance-Lifecycle", "no-target")
    rows.append({"route": "worker-pool", "status": status, "lifecycle": life, "instance": h.get("X-Instance-Id", "")})
    tally[("worker-pool", life, status)] += 1
    spot_seen += life == "spot"
    if i >= 59 and spot_seen >= 10:
        break
    time.sleep(0.2)

for _ in range(40):
    status, h = call({})
    life = h.get("X-Instance-Lifecycle", "no-target")
    rows.append({"route": "normal", "status": status, "lifecycle": life, "instance": h.get("X-Instance-Id", "")})
    tally[("normal", life, status)] += 1

with open(f"{out}/spot_guard_requests.csv", "w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=["route", "status", "lifecycle", "instance"])
    writer.writeheader()
    writer.writerows(rows)

print(f"\n{'route':<12} {'host':<10} {'status':>6} {'count':>6}")
for (route, life, status), n in sorted(tally.items()):
    print(f"{route:<12} {life:<10} {status:>6} {n:>6}")

checks = {
    "a Spot worker answered": spot_seen > 0,
    "Spot hosts answered critical requests only with 503":
        all(s == 503 for (r, l, s) in tally if l == "spot"),
    "On-Demand workers processed critical requests":
        any(s == 200 for (r, l, s) in tally if r == "worker-pool" and l == "on-demand"),
    "normally routed critical requests all succeeded on On-Demand":
        all(s == 200 and l == "on-demand" for (r, l, s) in tally if r == "normal"),
}
print()
for name, ok in checks.items():
    print(f"{'PASS' if ok else 'FAIL'}  {name}")
json.dump({"tally": {"|".join(map(str, k)): v for k, v in tally.items()}, "checks": checks},
          open(f"{out}/spot_guard_summary.json", "w"), indent=2)
sys.exit(0 if all(checks.values()) else 1)
EOF
RESULT=$?
set -e

upload_dir "$OUT" evidence
exit "$RESULT"
