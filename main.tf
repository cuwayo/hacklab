# hacklab — a ready-to-use reverse-engineering / dev VM on Hetzner Cloud.
#
# The Hetzner API token is read from the HCLOUD_TOKEN environment variable by the
# provider automatically — it is never written here.
#
# Provider/version requirements live in versions.tf.

# ---------------------------------------------------------------------------------
# Inputs that need computing at plan time
# ---------------------------------------------------------------------------------

# Resolve the public key path (expand ~) and read it.
locals {
  ssh_public_key_path = pathexpand(var.ssh_public_key_path)
  ssh_public_key      = trimspace(file(local.ssh_public_key_path))
}

# Look up the image by name so we fail early with a clear message if the slug is wrong
# (rather than at server-create time). most_recent picks the newest match.
data "hcloud_image" "os" {
  name        = var.image
  most_recent = true
}

# ---------------------------------------------------------------------------------
# SSH key
# ---------------------------------------------------------------------------------

resource "hcloud_ssh_key" "hacklab" {
  name       = "${var.server_name}-key"
  public_key = local.ssh_public_key
}

# ---------------------------------------------------------------------------------
# Firewall — inbound SSH only (+ ICMP), everything else outbound is allowed by default.
# ---------------------------------------------------------------------------------

resource "hcloud_firewall" "hacklab" {
  name = "${var.server_name}-fw"

  # SSH (port 22) from the allowed CIDRs.
  rule {
    description = "SSH from allowed CIDRs"
    direction   = "in"
    protocol    = "tcp"
    port        = "22"
    source_ips  = var.allowed_ssh_cidrs
  }

  # ICMP (ping / path MTU discovery) from anywhere.
  rule {
    description = "ICMP"
    direction   = "in"
    protocol    = "icmp"
    source_ips  = ["0.0.0.0/0", "::/0"]
  }
}

# ---------------------------------------------------------------------------------
# Console / rescue password
#
# This is for the Hetzner web console and rescue mode only — normal SSH login is
# key-based. It is stored in the OpenTofu state (see README security notes).
# ---------------------------------------------------------------------------------

resource "random_password" "user_password" {
  length           = 32
  special          = true
  override_special = "!#%*+-=?@_"
}

# ---------------------------------------------------------------------------------
# Server
# ---------------------------------------------------------------------------------

resource "hcloud_server" "hacklab" {
  name        = var.server_name
  image       = data.hcloud_image.os.name
  server_type = var.server_type
  location    = var.location
  ssh_keys    = [hcloud_ssh_key.hacklab.id]

  # cloud-init: creates the user, installs the toolchain, writes the ready marker.
  # The big provisioning logic lives in cloud-init/setup.sh; we read it and indent
  # it so it embeds cleanly under the write_files YAML block scalar. Keeping the
  # shell out of the template avoids Terraform's ${...} interpolation escaping.
  user_data = templatefile("${path.module}/cloud-init/cloud-init.yaml.tftpl", {
    server_name    = var.server_name
    username       = var.username
    ssh_public_key = local.ssh_public_key
    password_hash  = random_password.user_password.bcrypt_hash
    ghidra_version = var.ghidra_version
    ghidra_sha256  = var.ghidra_sha256
    jdk_package    = var.ghidra_jdk_package
    setup_script   = indent(6, file("${path.module}/cloud-init/setup.sh"))
  })

  firewall_ids = [hcloud_firewall.hacklab.id]

  labels = {
    project = "hacklab"
  }

  # Changing user_data forces a rebuild of the cloud-init data; the provider updates
  # it in place where the API allows. keep_disk avoids shrinking the disk on a resize.
  keep_disk = false
}
