# Remote state in the HOST app's Spaces bucket via the S3-compatible backend.
#
# Partial configuration: bucket, endpoint AND key come from backend.hcl, written
# by the bootstrap (gitignored). The key is not pinned here — unlike the host
# roots, which are alone in their bucket — because every tenant of a droplet
# shares the host's bucket, so each needs its own key:
#
#   tenants/<project_name>/terraform.tfstate
#
# Credentials come from AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY, which the
# bootstrap exports from SPACES_ACCESS_KEY_ID / SPACES_SECRET_ACCESS_KEY.
terraform {
  backend "s3" {
    region = "us-east-1" # required by the backend, ignored by Spaces

    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_s3_checksum            = true
  }
}
