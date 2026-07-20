variable "aws_region" {
  description = "AWS region where the infrastructure will be created"
  type        = string
  default     = "eu-north-1"
}

variable "project_name" {
  description = "Project name used for naming AWS resources"
  type        = string
  default     = "emartapp"
}

variable "instance_type" {
  # Must be free-tier-eligible or RunInstances rejects it. Check the list with:
  #   aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true
  description = "EC2 instance type (must be free-tier-eligible)"
  type        = string
  default     = "c7i-flex.large"
}

variable "key_name" {
  description = "Existing AWS key pair name used to SSH into the EC2 instance"
  type        = string
}

variable "ssh_allowed_cidr" {
  description = "Your public IP address in CIDR format. Example: 80.2.54.11/32"
  type        = string
}

variable "app_repo_url" {
  description = "Forked GitHub repo URL for the app"
  type        = string
  default     = "https://github.com/Uche-anya/emartapp.git"
}