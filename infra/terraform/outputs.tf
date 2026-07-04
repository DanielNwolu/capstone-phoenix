output "control_plane_public_ip" {
  description = "Public IP of the K3s control plane"
  value       = aws_instance.control_plane.public_ip
}

output "control_plane_private_ip" {
  description = "Private IP of the K3s control plane"
  value       = aws_instance.control_plane.private_ip
}

output "worker_public_ips" {
  description = "Public IPs of the K3s workers"
  value       = aws_instance.workers[*].public_ip
}
