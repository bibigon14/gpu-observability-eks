# kube-prometheus-stack: Prometheus Operator, Prometheus, Grafana, Alertmanager.
#
# Installed before the GPU Operator so the ServiceMonitor / PrometheusRule CRDs exist
# when the GPU Operator registers its dcgm-exporter ServiceMonitor.
#
# This keeps the repo self-contained: clone, apply, and the whole observability path
# runs in-cluster with no external dependency. To federate into a central Thanos
# instead, add a remote_write block under prometheus.prometheusSpec (see docs/architecture.md).

resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "65.1.1"
  namespace        = "monitoring"
  create_namespace = true
  timeout          = 600

  values = [yamlencode({
    grafana = {
      adminPassword = var.grafana_admin_password
      service = {
        type = "ClusterIP" # port-forward for the demo; no public LB
      }
      # Auto-load the GPU dashboard shipped in this repo (mounted via the sidecar).
      dashboardProviders = {
        "dashboardproviders.yaml" = {
          apiVersion = 1
          providers = [{
            name            = "gpu"
            orgId           = 1
            folder          = "GPU"
            type            = "file"
            disableDeletion = false
            editable        = true
            options         = { path = "/var/lib/grafana/dashboards/gpu" }
          }]
        }
      }
    }

    # Scrape ServiceMonitors in every namespace (the GPU Operator lives in gpu-operator,
    # vLLM in workloads). Without this the default stack only selects its own release.
    prometheus = {
      prometheusSpec = {
        serviceMonitorSelectorNilUsesHelmValues = false
        podMonitorSelectorNilUsesHelmValues     = false
        ruleSelectorNilUsesHelmValues           = false
        retention                               = "6h"
      }
    }
  })]
}
