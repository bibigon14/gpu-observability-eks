# NVIDIA GPU Operator.
#
# The EKS GPU-optimized AMI (AL2_x86_64_GPU) already provides the NVIDIA driver and
# the container toolkit, so we disable those operator components and let the operator
# own only the Kubernetes-facing pieces:
#   - device-plugin: advertises nvidia.com/gpu as a schedulable resource
#   - GFD (GPU Feature Discovery): labels nodes with GPU product / memory / count
#   - DCGM + dcgm-exporter: the observability source this whole project is about
#
# The GPU Operator's default dcgm-exporter metric set already includes the profiling
# counters that carry the real utilization signal - DCGM_FI_PROF_GR_ENGINE_ACTIVE,
# DCGM_FI_PROF_PIPE_TENSOR_ACTIVE, DCGM_FI_PROF_DRAM_ACTIVE, framebuffer memory - not
# just the misleading GPU_UTIL field. To swap in an explicit custom counter set
# (e.g. to add DCGM_FI_PROF_SM_ACTIVE), apply manifests/dcgm/ and restart the exporter;
# see docs/runbook.md. Kept out of the operator install to avoid a ConfigMap ordering
# dependency on first apply.

resource "helm_release" "gpu_operator" {
  name             = "gpu-operator"
  repository       = "https://helm.ngc.nvidia.com/nvidia"
  chart            = "gpu-operator"
  version          = "v24.6.2"
  namespace        = "gpu-operator"
  create_namespace = true
  timeout          = 600
  atomic           = true

  # Driver + toolkit come from the AMI.
  set {
    name  = "driver.enabled"
    value = "false"
  }
  set {
    name  = "toolkit.enabled"
    value = "false"
  }

  # Let the operator create a ServiceMonitor for dcgm-exporter so kube-prometheus-stack
  # scrapes it automatically (the Prometheus Operator CRDs are installed by monitoring.tf).
  set {
    name  = "dcgmExporter.serviceMonitor.enabled"
    value = "true"
  }

  depends_on = [helm_release.kube_prometheus_stack]
}
