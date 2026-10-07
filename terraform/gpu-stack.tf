# GPU stack for the EKS AL2023 accelerated AMI.
#
# The accelerated AMI already provides the NVIDIA driver and container runtime (AWS
# builds and tests them), so we do NOT run the GPU Operator - its driver lifecycle
# does not work cleanly on EKS AL2023 (the default driver version has no amzn2023
# image in nvcr.io, and the pre-installed-driver validator loops). Instead we deploy
# the two pieces we actually need directly against the host driver:
#   - nvidia-device-plugin: advertises nvidia.com/gpu to the scheduler
#   - dcgm-exporter: the Prometheus metrics source this project is about
#
# See docs/postmortem.md for the full path that led here.
#
# Chart versions are pinned to the resolved versions from the first green run (helm list -A)
# so a clean rebuild is reproducible and a new upstream chart can't silently change the stack.

locals {
  gpu_tolerations = [{
    key      = "nvidia.com/gpu"
    operator = "Equal"
    value    = "true"
    effect   = "NoSchedule"
  }]
  gpu_node_selector = {
    "workload-type" = "gpu"
  }
}

# --- NVIDIA device plugin ------------------------------------------------------

resource "helm_release" "nvidia_device_plugin" {
  name             = "nvidia-device-plugin"
  repository       = "https://nvidia.github.io/k8s-device-plugin"
  chart            = "nvidia-device-plugin"
  version          = "0.20.1" # pinned from the first green run (helm list -A)
  namespace        = "gpu-operator"
  create_namespace = true
  timeout          = 300

  values = [yamlencode({
    nodeSelector = local.gpu_node_selector
    tolerations  = local.gpu_tolerations
  })]
}

# --- DCGM exporter -------------------------------------------------------------

resource "helm_release" "dcgm_exporter" {
  name             = "dcgm-exporter"
  repository       = "https://nvidia.github.io/dcgm-exporter/helm-charts"
  chart            = "dcgm-exporter"
  version          = "4.8.4" # pinned from the first green run (helm list -A)
  namespace        = "gpu-operator"
  create_namespace = true
  timeout          = 300

  values = [yamlencode({
    nodeSelector = local.gpu_node_selector
    tolerations  = local.gpu_tolerations
    # Let kube-prometheus-stack scrape it (Prometheus Operator CRDs come from monitoring.tf).
    # NOTE: the chart hard-codes scrapeTimeout=25s and the Prometheus Operator rejects a
    # ServiceMonitor whose interval is shorter than its timeout, so interval must be >= 25s.
    # (A 5s interval here silently dropped the whole ServiceMonitor - see docs/postmortem.md.)
    serviceMonitor = {
      enabled  = true
      interval = "30s"
    }
  })]

  depends_on = [helm_release.kube_prometheus_stack]
}
