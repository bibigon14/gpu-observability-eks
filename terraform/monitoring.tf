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
      # The dashboard sidecar watches for ConfigMaps labeled grafana_dashboard and provisions
      # them into Grafana automatically. The GPU dashboard ships as exactly such a ConfigMap
      # (kubernetes_config_map_v1.gpu_dashboard below), so a clean apply brings Grafana up with
      # the dashboard already loaded - no manual import step.
      sidecar = {
        dashboards = {
          enabled         = true
          label           = "grafana_dashboard"
          searchNamespace = "monitoring"
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

# --- GPU dashboard ------------------------------------------------------------

# The GPU dashboard, shipped as a sidecar-discovered ConfigMap. The dashboard JSON carries
# no hard-coded datasource (templating.list is empty and no panel pins a datasource uid), so
# Grafana binds every panel to the default Prometheus datasource on whatever cluster this
# lands in - which is what makes it safe to provision blind on a freshly built cluster.
resource "kubernetes_config_map_v1" "gpu_dashboard" {
  metadata {
    name      = "gpu-utilization-vs-allocation"
    namespace = "monitoring"
    labels = {
      grafana_dashboard = "1"
    }
  }

  data = {
    "gpu-utilization-vs-allocation.json" = file("${path.module}/../dashboards/gpu-utilization-vs-allocation.json")
  }

  depends_on = [helm_release.kube_prometheus_stack]
}
