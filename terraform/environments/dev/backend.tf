# Remote state in the bucket that terraform/backend.tf created (KMS-encrypted,
# versioned, DynamoDB-locked). This block has to live here: Terraform only
# reads the backend from the folder it runs in.
#
# bucket / region / dynamodb_table / kms_key_id come from backend.hcl:
#   terraform -chdir=terraform output -raw backend_hcl > terraform/environments/dev/backend.hcl
#   terraform -chdir=terraform/environments/dev init -backend-config=backend.hcl
terraform {
  backend "s3" {
    key = "dev/terraform.tfstate"
  }
}
