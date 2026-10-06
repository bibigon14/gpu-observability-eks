output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "region" {
  description = "AWS region"
  value       = var.region
}

output "configure_kubectl" {
  description = "Run this to point kubectl at the cluster"
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}

output "grafana_port_forward" {
  description = "Open Grafana locally"
  value       = "kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80"
}

output "vllm_port_forward" {
  description = "Open the vLLM OpenAI-compatible API locally"
  value       = "kubectl -n workloads port-forward svc/vllm 8000:8000"
}
