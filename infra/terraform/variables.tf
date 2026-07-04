variable "aws_region" {
  description = "The AWS region to deploy resources into"
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "The EC2 instance type for the cluster"
  type        = string
  default     = "t3.small"
}

variable "admin_cidr" {
  description = "CIDR allowed to reach SSH and the Kubernetes API (your IP only)"
  type        = string
  default     = "102.90.98.57/32"
}
