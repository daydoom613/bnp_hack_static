#!/usr/bin/env bash
# Build the app image and push it to this account's ECR repo.
# deploy.yml does the same thing on main; this script is for manual pushes.
#
# Usage:  scripts/build_and_push.sh <tag> [ecr_repository_url]
#   tag   e.g. v1. ECR tags are immutable, so never reuse one.
#   url   defaults to $ECR_URL, then to the output of terraform/backend.tf.
#
# Uses your current AWS credentials: set AWS_PROFILE first.
set -euo pipefail

TAG="${1:?usage: $0 <tag> [ecr_repository_url]}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ECR_URL="${2:-${ECR_URL:-$(terraform -chdir="$ROOT/terraform" output -raw ecr_repository_url)}}"

REGISTRY="${ECR_URL%%/*}"                  # 123456789012.dkr.ecr.eu-west-1.amazonaws.com
REGION="$(echo "$REGISTRY" | cut -d. -f4)" # eu-west-1

aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"

# Built from the repo root: the image bakes in data/service_priority.xlsx (.dockerignore
# keeps the context to app/ and that file). t3 instances are x86_64; pin the platform so
# an ARM laptop can't push the wrong architecture.
docker build --platform linux/amd64 -f "$ROOT/app/Dockerfile" -t "$ECR_URL:$TAG" "$ROOT"
docker push "$ECR_URL:$TAG"

echo
echo "Pushed $ECR_URL:$TAG"
echo "Next: set image_tag = \"$TAG\" in terraform/environments/dev/terraform.tfvars and apply."
