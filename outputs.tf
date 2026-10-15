output "server_ipv4" {
  description = "Public IPv4 address of the hacklab server."
  value       = hcloud_server.hacklab.ipv4_address
}

output "ssh_command" {
  description = "Ready-to-copy SSH command (uses your configured username and key)."
  value       = "ssh ${var.username}@${hcloud_server.hacklab.ipv4_address}"
}

output "username" {
  description = "Login user created on the server."
  value       = var.username
}

output "password" {
  description = "Generated console/rescue password for the login user. Retrieve with: tofu output -raw password"
  value       = random_password.user_password.result
  sensitive   = true
}
