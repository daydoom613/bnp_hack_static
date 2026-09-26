#!/bin/bash
# shellcheck disable=SC2154  # the dollar-brace placeholders are Terraform templatefile() variables
# Rendered by Terraform templatefile() in terraform/environments/*/main.tf.
# Dollar-brace placeholders are filled in by Terraform. Bash variables must use
# the plain $VAR form so templatefile leaves them alone. Keep this file LF-only
# (see .gitattributes).
#
# Every -e below must match a name app/cloudscale/config.py reads.
set -euo pipefail
exec > >(tee -a /var/log/user-data.log | logger -t user-data) 2>&1

echo "user-data start: $(date -Is) role=${role}"

# iproute-tc provides tc for the network-latency chaos test.
dnf install -y docker iproute-tc
systemctl enable --now docker

TOKEN=$(curl -sS -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
INSTANCE_ID=$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)

# The NAT route or ECR can lag a few seconds behind boot, so retry.
pulled=false
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  if aws ecr get-login-password --region "${region}" | docker login --username AWS --password-stdin "${ecr_registry}" &&
    docker pull "${image}"; then
    pulled=true
    break
  fi
  echo "ECR login/pull failed (attempt $attempt/10), retrying in 15s"
  sleep 15
done

if [ "$pulled" != true ]; then
  echo "Could not pull ${image}; the ALB health check will fail and the ASG will replace this instance."
  exit 1
fi

docker rm -f app >/dev/null 2>&1 || true

# --stop-timeout: `docker stop` (drain Lambda, instance shutdown) waits this long
# for in-flight requests and jobs before killing the app.
# AWS_DEFAULT_REGION is for boto3's own defaults; AWS_REGION is the contract name.
docker run -d --name app --restart always --stop-timeout 90 \
  -p ${app_port}:8080 \
  --log-driver awslogs \
  --log-opt awslogs-region=${region} \
  --log-opt awslogs-group=${log_group} \
  --log-opt awslogs-stream="${role}-$INSTANCE_ID" \
  --log-opt mode=non-blocking \
  -e ROLE="${role}" \
  -e DB_HOST="${db_host}" \
  -e DB_NAME="${db_name}" \
  -e DB_SECRET_ARN="${db_secret_arn}" \
  -e QUEUE_URL="${queue_url}" \
  -e CRITICAL_WORK_MS="${critical_work_ms}" \
  -e NONCRITICAL_WORK_MS="${noncritical_work_ms}" \
  -e JOB_WORK_MS="${job_work_ms}" \
  -e AWS_REGION="${region}" \
  -e AWS_DEFAULT_REGION="${region}" \
  "${image}"

echo "user-data done: $(date -Is), ${role} container started from ${image}"
