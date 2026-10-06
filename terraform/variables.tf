variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-west-2"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "gpu-observability-demo"
}

variable "cluster_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.30"
}

variable "vpc_cidr" {
  description = "VPC CIDR"
  type        = string
  default     = "10.30.0.0/16"
}

# --- GPU node group -----------------------------------------------------------

variable "gpu_instance_type" {
  description = "GPU instance type. g4dn.xlarge = 1x NVIDIA T4 (16GB), 4 vCPU."
  type        = string
  default     = "g4dn.xlarge"
}

variable "gpu_capacity_type" {
  description = "SPOT (cheap, ~70% off) or ON_DEMAND (fallback if no spot capacity)."
  type        = string
  default     = "SPOT"
}

variable "gpu_desired_size" {
  description = "Desired GPU nodes. Keep 1 for the demo; destroy when done."
  type        = number
  default     = 1
}

variable "gpu_min_size" {
  description = "Min GPU nodes. 0 lets the group scale to zero when idle."
  type        = number
  default     = 1
}

variable "gpu_max_size" {
  description = "Max GPU nodes."
  type        = number
  default     = 1
}

# --- Monitoring ---------------------------------------------------------------

variable "grafana_admin_password" {
  description = "Grafana admin password for kube-prometheus-stack. Set via TF_VAR_grafana_admin_password, never commit it."
  type        = string
  sensitive   = true
  default     = "changeme-set-via-env"
}
