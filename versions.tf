terraform {
  # OpenTofu 1.6+ is required for the features used here (testing/lockfile maturity).
  # Verified locally against OpenTofu v1.13.1.
  required_version = ">= 1.6.0"

  required_providers {
    hcloud = {
      source = "hetznercloud/hcloud"
      # Pinned to the version verified when this project was written (v1.70.0).
      version = "~> 1.70"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }
}
