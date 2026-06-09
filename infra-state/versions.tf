# State-bucket root module. Holds exactly ONE resource: the Spaces bucket the
# OTHER two roots store their state in.
#
# Its own state is deliberately LOCAL — the bucket can't store the state that
# creates it (chicken/egg). Losing this local state is a non-event: re-adopt
# the bucket with
#   terraform import digitalocean_spaces_bucket.tfstate <region>,<bucket-name>
terraform {
  required_version = ">= 1.6"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.87"
    }
  }
}

provider "digitalocean" {
  token             = var.do_token
  spaces_access_id  = var.spaces_access_id
  spaces_secret_key = var.spaces_secret_key
}
