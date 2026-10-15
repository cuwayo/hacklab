# All variables are overridable via -var, HCLOUD_* env, or a terraform.tfvars file
# (see terraform.tfvars.example). Defaults are chosen to "just work".

variable "image" {
  description = "Hetzner Cloud image name for the server. Ubuntu 26.04 LTS is available as the Rapid Deploy image 'ubuntu-26.04' (Hetzner API changelog, 2026-05-18)."
  type        = string
  default     = "ubuntu-26.04"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.\\-]*$", var.image))
    error_message = "The image name must look like a Hetzner image slug, e.g. \"ubuntu-26.04\"."
  }
}

variable "server_type" {
  # Ghidra is memory-hungry, so we require >= 8 GB RAM and >= 4 vCPU.
  # cpx32 = 4 vCPU / 8 GB RAM / 160 GB NVMe, ~EUR 35.49/mo (excl. IPv4), available in nbg1/fsn1.
  # Cheaper alternative: cx33 (4 vCPU / 8 GB, ~EUR 8.49/mo) — but the whole Cost-Optimized
  # (CX) tier is currently shown "not available" on Hetzner's pricing page, so it is not a safe default.
  description = "Hetzner Cloud x86 server type (>= 8 GB RAM, >= 4 vCPU recommended for Ghidra)."
  type        = string
  default     = "cpx32"
}

variable "location" {
  description = "Hetzner Cloud location, e.g. nbg1 (Nuremberg) or fsn1 (Falkenstein). Note: CPX Gen2 capacity in fsn1 is currently tight; nbg1 is the safer default."
  type        = string
  default     = "nbg1"

  validation {
    condition     = contains(["nbg1", "fsn1", "hel1", "ash", "hil", "sin"], var.location)
    error_message = "location must be one of: nbg1, fsn1, hel1, ash, hil, sin."
  }
}

variable "server_name" {
  description = "Name of the Hetzner Cloud server (also its hostname)."
  type        = string
  default     = "hacklab"
}

variable "username" {
  description = "Login user to create on the server (bash shell, sudo group, passwordless sudo)."
  type        = string
  default     = "user"

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]{0,31}$", var.username))
    error_message = "username must be a valid Linux username (lowercase letters, digits, _ or -, starting with a letter or _)."
  }
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key installed for the login user. Defaults to the standard ed25519 key."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "allowed_ssh_cidrs" {
  # WARNING: 0.0.0.0/0 exposes SSH to the whole internet. Restrict this to your own IP.
  description = "CIDRs allowed to reach SSH (port 22). Default is wide open — set this to your own IP, e.g. [\"203.0.113.7/32\"]."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ghidra_version" {
  description = "Ghidra release to install (official GitHub releases). Either a bare version (\"12.1.4\") or the full tag (\"Ghidra_12.1.4_build\"); \"latest\" resolves via the GitHub API at provision time."
  type        = string
  default     = "12.1.4"
}

variable "ghidra_sha256" {
  description = "Optional pinned SHA-256 for the Ghidra zip. Leave empty to use the checksum GitHub publishes in the release (asset digest / release notes). Only set this if you also pin ghidra_version."
  type        = string
  default     = ""
}

variable "ghidra_jdk_package" {
  description = "apt package for the JDK Ghidra requires. Ghidra 12.1.x requires JDK 21 (64-bit); openjdk-21-jdk is available in Ubuntu 26.04 (resolute)."
  type        = string
  default     = "openjdk-21-jdk"
}
