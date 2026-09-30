variable "region" {
  default     = "us-east-1"
  description = "Region every resource in this architecture is created in."
}

variable "name" {
  default     = "jenkins"
  description = "Name prefix applied to every resource, so one account can hold several copies of this architecture without collision."
}

variable "vpc_cidr" {
  default     = "10.0.0.0/16"
  description = "IPv4 range for the VPC. Each tier carves a /24 out of it per availability zone."
}

variable "availability_zone_count" {
  default     = 2
  description = "Availability zones to spread across. Two is the minimum for a load balancer AWS will accept, and it is what lets the controller restart in a surviving zone."

  validation {
    condition     = var.availability_zone_count >= 2
    error_message = "This architecture needs at least two availability zones: an application load balancer requires subnets in two, and a controller that can only restart into one zone is not recoverable."
  }
}

variable "controller_image" {
  default     = "jenkins/jenkins:lts-jdk21"
  description = "Container image the controller runs. Pin a digest rather than a tag for a reproducible controller."
}

variable "controller_cpu" {
  default     = 1024
  description = "Fargate CPU units for the controller. 1024 is one vCPU."
}

variable "controller_memory" {
  default     = 2048
  description = "Fargate memory for the controller, in mebibytes. Jenkins is JVM-based and unhappy below 2048."
}

variable "agent_cpu" {
  default     = 1024
  description = "Fargate CPU units advertised for build agents. The controller launches agents itself, so this is recorded as an output rather than used to create anything."
}

variable "agent_memory" {
  default     = 2048
  description = "Fargate memory advertised for build agents, in mebibytes."
}

variable "allowed_cidr_blocks" {
  default     = ["0.0.0.0/0"]
  description = "IPv4 ranges permitted to reach the load balancer. Defaults to the whole internet, which is almost never what a build system should accept — narrow it to your office and VPN ranges."
}

variable "domain_name" {
  default     = null
  description = "Domain the controller is served on. Setting it creates a public hosted zone, an ACM certificate, and an alias record, and moves the listener to HTTPS. If null, the load balancer's own DNS name is the entry point over plain HTTP."
}

variable "enable_global_accelerator" {
  default     = false
  description = "Whether to front the load balancer with a Global Accelerator, giving two static anycast addresses routed over AWS's own backbone. This is the first step toward serving the controller globally — see the Design section."
}

variable "efs_backup" {
  default     = true
  description = "Whether EFS keeps its own automatic daily backups, in addition to the AWS Backup plan. Both are cheap relative to losing a controller's history."
}

variable "log_retention_days" {
  default     = 90
  description = "Days the controller's logs are retained. Build logs are the audit trail for what shipped, so a short retention is a real loss."
}

variable "alarm_email" {
  default     = null
  description = "Address subscribed to the alarm topic. An email subscription stays pending until the recipient confirms it, so alarms deliver nothing until then."
}

variable "monthly_budget" {
  default     = null
  description = "Monthly spend in USD to alarm on, as a string. If null, no budget is created."
}

variable "tags" {
  default     = null
  description = "A map of tags applied to every resource in the architecture."
}
