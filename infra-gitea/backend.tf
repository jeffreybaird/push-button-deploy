# Remote state in DO Spaces via the S3-compatible backend — same shape as
# infra-persistent/backend.tf and infra-app/backend.tf. Unlike those two
# (copied per-app into <app_dir>/infra/ and applied from there), this root is
# a SINGLETON — there's one Gitea instance, not one per app — so it's applied
# directly from here in this repo by bootstrap-gitea.sh, never copied.
terraform {
  backend "s3" {
    key    = "infra-gitea/terraform.tfstate"
    region = "us-east-1" # required by the backend, ignored by Spaces

    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_s3_checksum            = true
  }
}
