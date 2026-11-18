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

variable "vpc_cidr" {
  description = "Address range of the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "db_port" {
  description = "Port of the PostgreSQL database"
  type        = number
  default     = 5432
}

variable "db_name" {
  description = "Name of the first database inside the instance"
  type        = string
  default     = "tutorials"
}

variable "db_username" {
  description = "Master user of the database"
  type        = string
  default     = "tutorials_admin"
}

variable "db_password" {
  description = "Master password of the database. Set it in terraform.tfvars, never commit it"
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.db_password) >= 8 && can(regex("^[^/@\" ]+$", var.db_password))
    error_message = "The password needs at least 8 characters and must not contain a slash, an @, a double quote or a space."
  }
}

variable "db_instance_class" {
  description = "Size of the database server"
  type        = string
  default     = "db.t3.micro"
}

variable "db_allocated_storage" {
  description = "Disk size in GB"
  type        = number
  default     = 20
}

variable "db_engine_version" {
  description = "PostgreSQL major version"
  type        = string
  default     = "16"
}
