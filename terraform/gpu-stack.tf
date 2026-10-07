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
# Chart versions are intentionally left unpinned for the first working run; pin them
# to the resolved versions once the stack is green (helm list -A shows them).

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
  namespace        = "gpu-operator"
  create_namespace = true
  timeout          = 300

  values = [yamlencode({
    nodeSelector = local.gpu_node_selector
    tolerations  = local.gpu_tolerations
    # Let kube-prometheus-stack scrape it (Prometheus Operator CRDs come from monitoring.tf).
    serviceMonitor = {
      enabled  = true
      interval = "5s"
    }
  })]

  depends_on = [helm_release.kube_prometheus_stack]
}
