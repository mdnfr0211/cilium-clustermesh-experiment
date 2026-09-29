variable "aws_region" {
  description = "AWS region for both clusters"
  type        = string
  default     = "ap-south-1"
}

variable "cluster_1_name" {
  description = "First EKS cluster name"
  type        = string
  default     = "cluster-1"
}

variable "cluster_2_name" {
  description = "Second EKS cluster name"
  type        = string
  default     = "cluster-2"
}
