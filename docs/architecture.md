# Architecture

## Cluster layout

Two managed node groups:

- **system** - `t3.large` on-demand, 2-3 nodes. Runs the platform: Prometheus Operator,
  Prometheus, Grafana, Alertmanager, and the GPU Operator's control-plane pods. No GPU,
  no taint.
- **gpu** - `g4dn.xlarge` spot (one NVIDIA T4, 16GB), 1 node for the demo. Tainted
  `nvidia.com/gpu=true:NoSchedule` and labelled `workload-type=gpu` so only GPU workloads
  land there. Uses the EKS GPU-optimized AMI (`AL2_x86_64_GPU`).

## Driver ownership

The GPU-optimized AMI ships the NVIDIA driver and the container toolkit. The GPU Operator
is therefore installed with `driver.enabled=false` and `toolkit.enabled=false`, and owns
only:

- **device-plugin** - advertises `nvidia.com/gpu` to the scheduler
- **GFD** (GPU Feature Discovery) - labels nodes with GPU product, memory, count
- **DCGM + dcgm-exporter** - the metrics source

This is the reliable EKS pattern: let the AMI own the kernel-coupled bits that are painful
to install at runtime, let the operator own the Kubernetes-facing bits.

## Metrics path

```
dcgm-exporter (:9400)  --ServiceMonitor-->  Prometheus
vLLM (/metrics :8000)  --ServiceMonitor-->  Prometheus
Prometheus  -->  Grafana dashboard  +  PrometheusRule alerts  -->  Alertmanager
```

`kube-prometheus-stack` is installed first so the `ServiceMonitor` / `PrometheusRule` CRDs
exist when the GPU Operator and the workload manifests register theirs. Prometheus is set
to select ServiceMonitors in all namespaces (`serviceMonitorSelectorNilUsesHelmValues:
false`), otherwise it would only scrape its own release.

## Why in-cluster (and how to federate)

Everything is scraped in-cluster so the repo is self-contained - clone and apply, no
external Prometheus or tunnel required. To ship into a central/long-term store instead,
add a `remote_write` block under `prometheus.prometheusSpec` in `terraform/monitoring.tf`:

```yaml
prometheus:
  prometheusSpec:
    remoteWrite:
      - url: https://<central-prometheus-or-thanos-receive>/api/v1/receive
```

## Sharing model

The T4 has no MIG, so sub-GPU sharing is **time-slicing** (software, no isolation) -
see `manifests/time-slicing/`. On A100/A30/H100 the same packing goal is met with MIG
(hardware partitions, real memory and fault isolation), configured through the operator's
`mig.strategy` and a MIG profile per node. The trade-off is documented in the
GPU/AI Infrastructure domain reference.
