# =============================================================================
# One-time account setup: creates the remote-state BACKEND that
# environments/dev uses, plus the two things that must exist before the first
# deploy. Run it once, by hand, from this folder:
#
#   terraform -chdir=terraform init
#   terraform -chdir=terraform apply \
#     -var aws_account_id=123456789012 -var owner=you@example.com \
#     -var cost_center=1001 -var github_repo=your-org/finops-cloudscale
#
# Creates:
#   * S3 state bucket    KMS-encrypted (customer-managed key), versioned, private, TLS-only
#   * DynamoDB table     state locking
#   * ECR repository     the app image must be pushed before instances boot
#   * GitHub OIDC role   CI cannot create the role it uses to log in
#   * AWS Budget         e-mails the owner at 50/80/100% of the account credit (credit_budget)
#
# This file does NOT contain a `backend` block. Terraform only reads the backend
# block from the folder it runs in, so that lives in environments/dev/backend.tf.
# This config keeps LOCAL state (it creates the bucket, so it cannot be stored in
# it). Terraform ignores subfolders, so modules/ and environments/ are unaffected.
# =============================================================================

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }
}

provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = {
      Owner       = var.owner
      Project     = var.project
      Environment = var.environment
      Cost_Center = var.cost_center
      Stack       = "shared"
      ManagedBy   = "terraform"
    }
  }
}

# -----------------------------------------------------------------------------
# Inputs (use the same values as environments/dev/terraform.tfvars)
# -----------------------------------------------------------------------------
variable "aws_region" {
  type    = string
  default = "eu-west-1"
}

variable "aws_account_id" {
  description = "The STATIC account id. The provider refuses to run against any other account."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must be the 12-digit AWS account id."
  }
}

variable "project" {
  type    = string
  default = "finops-cloudscale"
}

variable "environment" {
  description = "Environment tag (dev, staging or prod). Also the GitHub environment deploy.yml applies from."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of dev, staging, prod."
  }
}

variable "owner" {
  description = "Owner tag: e-mail of the product owner."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.owner))
    error_message = "owner must be an e-mail address."
  }
}

variable "cost_center" {
  description = "Cost_Center tag: numeric charge-back code."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.cost_center))
    error_message = "cost_center must be numeric."
  }
}

variable "github_repo" {
  description = "Repository allowed to assume the CI role, as owner/name."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repo))
    error_message = "github_repo must look like owner/name."
  }
}

variable "create_github_oidc_provider" {
  description = "false if the account already has the token.actions.githubusercontent.com provider."
  type        = bool
  default     = true
}

variable "credit_budget" {
  description = "Real money guard: the account's AWS credit in USD. Alerts on spend BEFORE credits are applied."
  type        = number
  default     = 120
}

variable "mfa_delete_enabled" {
  description = <<-EOT
    MFA-Delete can only be switched on by the ROOT user with an MFA code, so
    Terraform cannot do it. Run the command in terraform/README.md as root,
    then pass -var mfa_delete_enabled=true so Terraform stops reporting drift.
  EOT
  type        = bool
  default     = false
}

locals {
  name              = "${var.project}-${var.environment}"
  state_bucket_name = "${local.name}-tfstate-${var.aws_account_id}"
}

# -----------------------------------------------------------------------------
# KMS key for state
# -----------------------------------------------------------------------------
resource "aws_kms_key" "state" {
  description             = "${local.name} Terraform state encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

resource "aws_kms_alias" "state" {
  name          = "alias/${local.name}-tfstate"
  target_key_id = aws_kms_key.state.key_id
}

# -----------------------------------------------------------------------------
# State bucket
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket_name

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status     = "Enabled"
    mfa_delete = var.mfa_delete_enabled ? "Enabled" : "Disabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }

  depends_on = [aws_s3_bucket_versioning.state]
}

data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.state]
}

# -----------------------------------------------------------------------------
# Lock table
# -----------------------------------------------------------------------------
resource "aws_dynamodb_table" "lock" {
  name         = "${local.name}-tflock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.state.arn
  }

  point_in_time_recovery {
    enabled = true
  }
}

# -----------------------------------------------------------------------------
# ECR. Deploy order: this file -> push <ecr-url>:v1 -> environments/dev apply.
# -----------------------------------------------------------------------------
resource "aws_ecr_repository" "app" {
  name = "${var.project}-app"
  # A tag (v1, v2, ...) can never be overwritten, so image_tag always means one image.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the 20 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 20
      }
      action = { type = "expire" }
    }]
  })
}

# -----------------------------------------------------------------------------
# GitHub Actions OIDC role for .github/workflows/deploy.yml (no stored AWS keys)
# -----------------------------------------------------------------------------
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # AWS no longer checks these for GitHub, but older providers still require the field.
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  github_oidc_provider_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

data "aws_iam_policy_document" "ci_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # PR plans, pushes to main, and jobs that run in the GitHub environment
    # named after var.environment (deploy.yml applies with `environment: dev`).
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_repo}:pull_request",
        "repo:${var.github_repo}:ref:refs/heads/main",
        "repo:${var.github_repo}:environment:${var.environment}",
      ]
    }
  }
}

resource "aws_iam_role" "ci" {
  name                 = "${local.name}-github-ci"
  description          = "Assumed by GitHub Actions (deploy.yml) to plan and apply environments/${var.environment}"
  assume_role_policy   = data.aws_iam_policy_document.ci_trust.json
  max_session_duration = 14400 # the advanced test job runs ~2 h
}

# PowerUserAccess covers every service the stack uses except IAM.
resource "aws_iam_role_policy_attachment" "ci_power_user" {
  role       = aws_iam_role.ci.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

# IAM is limited to roles, policies and instance profiles named <project>-<environment>-*
# (this stack's own), so CI can never touch anything else in a shared account.
data "aws_iam_policy_document" "ci_iam" {
  statement {
    sid = "ReadIam"
    actions = [
      "iam:Get*",
      "iam:List*",
    ]
    resources = ["*"]
  }

  statement {
    sid = "ManageProjectIam"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:TagPolicy",
      "iam:UntagPolicy",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:UntagInstanceProfile",
      "iam:PassRole",
    ]
    resources = [
      "arn:aws:iam::${var.aws_account_id}:role/${local.name}-*",
      "arn:aws:iam::${var.aws_account_id}:policy/${local.name}-*",
      "arn:aws:iam::${var.aws_account_id}:instance-profile/${local.name}-*",
    ]
  }
}

resource "aws_iam_role_policy" "ci_iam" {
  name   = "${local.name}-ci-iam"
  role   = aws_iam_role.ci.id
  policy = data.aws_iam_policy_document.ci_iam.json
}

# -----------------------------------------------------------------------------
# Credit guard. The FinOps budget_cap (data/budget_cap.txt) guards each plan;
# this budget watches the whole account's actual spend against the credit.
# include_credit = false: credits would otherwise make the spend look like $0.
# -----------------------------------------------------------------------------
resource "aws_budgets_budget" "credits" {
  name         = "${local.name}-credits"
  budget_type  = "COST"
  limit_amount = tostring(var.credit_budget)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_types {
    include_credit = false
    include_refund = false
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.owner]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.owner]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.owner]
  }
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}

output "lock_table" {
  value = aws_dynamodb_table.lock.name
}

output "ecr_repository_url" {
  description = "Push the app image here (scripts/build_and_push.sh or deploy.yml)."
  value       = aws_ecr_repository.app.repository_url
}

output "ci_role_arn" {
  description = "Save as the GitHub secret AWS_ROLE_ARN."
  value       = aws_iam_role.ci.arn
}

# terraform -chdir=terraform output -raw backend_hcl > terraform/environments/dev/backend.hcl
output "backend_hcl" {
  description = "Backend settings for environments/dev/backend.hcl."
  value       = <<-EOT
    bucket         = "${aws_s3_bucket.state.bucket}"
    region         = "${var.aws_region}"
    dynamodb_table = "${aws_dynamodb_table.lock.name}"
    kms_key_id     = "${aws_kms_key.state.arn}"
    encrypt        = true
  EOT
}
