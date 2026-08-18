# Droplet firewall: SSH locked to your CIDR(s); HTTP/HTTPS open to the world
# (Caddy needs 80 for the ACME challenge + redirect, 443 for traffic); all
# egress allowed (pull images, reach the DB, fetch certs).

resource "digitalocean_firewall" "app" {
  name        = "${local.project_name}-app-fw"
  droplet_ids = [digitalocean_droplet.app.id]

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = var.ssh_cidrs
  }

  # A self-hosted Gitea Actions runner (GIT_PROVIDER=gitea) has a stable IP,
  # unlike a GitHub-hosted runner's — so it's allow-listed HERE, once, instead
  # of the GitHub path's per-deploy "punch a hole, revoke in always()" dance
  # (app/.github/workflows/deploy.yml). Empty var.gitea_runner_cidr (the
  # GitHub-path default) emits no block at all.
  dynamic "inbound_rule" {
    for_each = length(var.gitea_runner_cidr) > 0 ? [1] : []
    content {
      protocol         = "tcp"
      port_range       = "22"
      source_addresses = var.gitea_runner_cidr
    }
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "80"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "443"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}
