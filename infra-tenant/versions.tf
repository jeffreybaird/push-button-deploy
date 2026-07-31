terraform {
  required_version = ">= 1.6"

  required_providers {
    dnsimple = {
      source  = "dnsimple/dnsimple"
      version = "~> 2.1"
    }
  }
}

# No digitalocean provider: a tenant creates no DO resources at all. It reads
# the host's state (which needs only Spaces credentials, via the S3 backend) and
# writes one DNS record.
provider "dnsimple" {
  token   = var.dnsimple_token
  account = var.dnsimple_account
}
