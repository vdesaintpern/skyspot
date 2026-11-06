output "instance_id" {
  description = "Jumpbox instance id - pass to connect.sh / aws ssm start-session."
  value       = aws_instance.jumpbox.id
}

output "region" {
  value = var.region
}

output "private_ip" {
  value = aws_instance.jumpbox.private_ip
}

output "connect_hint" {
  description = "Example tunnel command."
  value       = "./connect.sh ${aws_instance.jumpbox.id} <model-private-ip> 8000 8000  # then: curl localhost:8000/v1/models"
}
