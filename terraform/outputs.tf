output "ec2_public_ip" {
  description = "Public IP address of the EC2 instance"
  value       = aws_instance.emartapp_server.public_ip
}

output "app_url" {
  description = "URL to access the application"
  value       = "http://${aws_instance.emartapp_server.public_ip}"
}

output "ssh_command" {
  description = "SSH command for connecting to the EC2 instance"
  value       = "ssh -i <your-key.pem> ubuntu@${aws_instance.emartapp_server.public_ip}"
}