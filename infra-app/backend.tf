# Remote state in DO Spaces via the S3-compatible backend (story 7.4).
# Same shape as infra-persistent/backend.tf — separate key, same bucket.
# See that file for the why behind the skip_* flags and the locking note.
terraform {
  backend "s3" {
    key    = "infra-app/terraform.tfstate"
    region = "us-east-1" # required by the backend, ignored by Spaces

    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_s3_checksum            = true
  }
}
