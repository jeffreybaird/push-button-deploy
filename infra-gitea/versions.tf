terraform {
  required_version = ">= 1.6"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.87"
    }
    dnsimple = {
      source  = "dnsimple/dnsimple"
      version = "~> 2.1"
    }
  }
}

provider "digitalocean" {
  token = var.do_token
}

provider "dnsimple" {
  token   = var.dnsimple_token
  account = var.dnsimple_account
}
