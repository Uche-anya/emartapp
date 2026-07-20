output "ec2_public_ip" {
  description = "Elastic IP of the EC2 instance. Use this for the EC2_HOST secret."
  value       = aws_eip.emartapp_server.public_ip
}

output "app_url" {
  description = "URL to access the application"
  value       = "http://${aws_eip.emartapp_server.public_ip}"
}

output "ssh_command" {
  description = "SSH command for connecting to the EC2 instance"
  value       = "ssh -i <your-key.pem> ubuntu@${aws_eip.emartapp_server.public_ip}"
}