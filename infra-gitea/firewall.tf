# Gitea's own firewall. Port 22 is the DROPLET's admin SSH (root@), locked to
# ssh_cidrs like an app droplet's — separate from Gitea's own git+ssh clone
# port (2222), which is open to the world the way any git host's SSH clone
# port is (cloning/pushing over SSH is meant to work from anywhere; the
# security boundary there is the SSH key/token, not the source IP).
#
# NOTE: there is deliberately NO inbound rule here for the runner's outbound
# SSH to app droplets — that's an EGRESS concern of THIS firewall (already
# open, see below) and an INGRESS concern of the APP droplet's own firewall
# (infra-app/firewall.tf's gitea_runner_cidr, allow-listing THIS droplet's IP).

resource "digitalocean_firewall" "gitea" {
  name        = "${var.project_name}-fw"
  droplet_ids = [digitalocean_droplet.gitea.id]

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = var.ssh_cidrs
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

  # Gitea's built-in git+ssh server (mapped to a non-22 host port so it
  # doesn't collide with the droplet's own OpenSSH daemon — see
  # gitea-host/docker-compose.yaml).
  inbound_rule {
    protocol         = "tcp"
    port_range       = "2222"
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
