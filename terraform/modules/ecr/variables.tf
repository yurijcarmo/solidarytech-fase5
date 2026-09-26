variable "project_name" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "services" {
  description = "List of service names to create ECR repositories for"
  type        = list(string)
  default     = ["ngo-service", "donation-service", "volunteer-service"]
}
