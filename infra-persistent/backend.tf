# Remote state in DO Spaces via the S3-compatible backend (story 7.4).
#
# Partial configuration: bucket + endpoints come from backend.hcl, written by
# the bootstrap (gitignored):
#   terraform init -backend-config=backend.hcl
# Credentials come from AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY, which the
# bootstrap exports from SPACES_ACCESS_KEY_ID / SPACES_SECRET_ACCESS_KEY.
#
# The skip_* flags disable AWS-only behaviors Spaces doesn't implement
# (STS/account lookups, region validation, SDK checksums). No state locking:
# Spaces has no DynamoDB equivalent, and provisioning is a single-operator,
# local-only act by design (locked decision).
terraform {
  backend "s3" {
    key    = "infra-persistent/terraform.tfstate"
    region = "us-east-1" # required by the backend, ignored by Spaces

    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_s3_checksum            = true
  }
}
