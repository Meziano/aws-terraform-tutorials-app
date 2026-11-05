variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "eu-central-1"
}

variable "project_name" {
  description = "Prefix for resource names"
  type        = string
  default     = "tutorials-app"
}

variable "callback_urls" {
  description = "Addresses Cognito may redirect to after login"
  type        = list(string)
  default     = ["http://127.0.0.1:5500/callback.html"]
}

variable "logout_urls" {
  description = "Addresses Cognito may redirect to after logout"
  type        = list(string)
  default     = ["http://127.0.0.1:5500/index.html"]
}
