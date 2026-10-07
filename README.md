# GPU Observability on EKS

Reliability and cost observability for GPU workloads on Amazon EKS. A real, applyable
cluster that provisions a GPU node pool on the EKS accelerated AMI, runs the **NVIDIA
device plugin** and **DCGM exporter** against the AMI's built-in driver, serves a live
model with **vLLM**, and surfaces the one metric that actually drives GPU cost: **the gap
between a GPU being _allocated_ and a GPU doing _work_.**

Built to be stood up, demonstrated, and destroyed the same day. `g4dn.xlarge`
(one NVIDIA T4), so a full apply/demo/destroy cycle costs a few dollars.

> Companion to a broader multi-cloud Terraform portfolio
> ([terraform-eks-platform](https://github.com/bibigon14/terraform-eks-platform),
> [terraform-gke-platform](https://github.com/bibigon14/terraform-gke-platform),
> [terraform-aks-platform](https://github.com/bibigon14/terraform-aks-platform)).

## Why this exists

GPUs are the most expensive compute in a cluster, and the default scheduler view of them
is binary and misleading:

- A pod requests `nvidia.com/gpu: 1` and holds a **whole** card. There is no "millicore"
  equivalent - allocation is all-or-nothing unless you configure time-slicing or MIG.
- `nvidia-smi` / `DCGM_FI_DEV_GPU_UTIL` reports "utilization" that only means _a kernel
  was running_. A tiny kernel on one SM shows 100%. A card can look saturated and be
  almost idle.

So the expensive failure mode is a GPU that is **allocated but idle**: memory reserved,
a workload resident, engines doing nothing. On a fleet of A100s that gap is burned money.
This project makes it visible and alerts on it.

## The gap, on a live T4

Both captured from the shipped Grafana dashboard against a real `g4dn.xlarge` (Tesla T4),
with vLLM serving `facebook/opt-1.3b`.

**Allocated but idle** - vLLM resident in ~13 GB of framebuffer, every engine flat at zero.
One whole T4 reserved and doing nothing: the exact state the `GPUAllocatedButIdle` alert
fires on.

![GPU allocated but idle](docs/screenshots/01-idle.png)

**Under load** - the same card driven by 24 concurrent inference streams. `GPU_UTIL` and the
graphics engine peg near 85%, but the **tensor cores** (`TENSOR_ACTIVE`) sit at ~13% while
**memory bandwidth** (`DRAM_ACTIVE`) climbs to ~70%. The workload is memory-bound, not
compute-bound: "GPU utilization" says the card is busy, the profiling counters say you are
paying for tensor cores you are not using. That divergence is the whole point.

![GPU under load - the utilization gap](docs/screenshots/02-under-load.png)

## Architecture

EKS in `us-west-2`, two managed node groups:

```mermaid
flowchart TB
  subgraph GPU["GPU node group - g4dn.xlarge, T4, tainted nvidia.com/gpu"]
    direction LR
    DP["nvidia-device-plugin<br/>advertises nvidia.com/gpu"]
    DCGM["dcgm-exporter<br/>:9400 /metrics"]
    VLLM["vLLM<br/>facebook/opt-1.3b (fp16)"]
  end

  subgraph SYS["System node group - t3.large on-demand"]
    PROM["Prometheus + Grafana<br/>kube-prometheus-stack"]
  end

  DCGM -->|ServiceMonitor| PROM
  VLLM -->|ServiceMonitor /metrics| PROM
  PROM -->|"GPUAllocatedButIdle<br/>GPUHighMemoryPressure"| ALERT["Alertmanager"]
  PROM --> DASH["Grafana dashboard:<br/>GPU_UTIL vs engine activity"]
```

Driver and container runtime come from the EKS GPU-optimized accelerated AMI
(`AL2023_x86_64_NVIDIA`), which AWS builds and tests per Kubernetes version. Rather than the
full **GPU Operator** - whose driver lifecycle does not work cleanly on EKS AL2023 - the
cluster runs only the two pieces it actually needs against that host driver: the device
plugin (advertises `nvidia.com/gpu`) and dcgm-exporter (the Prometheus metrics source). The
operator dead-ends that led here are written up in [`docs/postmortem.md`](docs/postmortem.md).
Everything is scraped **in-cluster** - no external dependency, clone and apply.

## What's in here

| Path | What |
|------|------|
| `terraform/` | VPC + EKS, a CPU system pool and a spot GPU pool; nvidia-device-plugin + dcgm-exporter and kube-prometheus-stack via `helm_release` |
| `manifests/vllm/` | vLLM serving a small model, plus a ServiceMonitor for its Prometheus metrics |
| `manifests/loadgen/` | A Job that drives real inference load so the dashboards show activity |
| `manifests/dcgm/` | Optional custom DCGM counter set (adds `SM_ACTIVE`) |
| `manifests/time-slicing/` | Time-slicing config - software GPU sharing for the T4 (no MIG) |
| `manifests/alerts/` | `GPUAllocatedButIdle` and `GPUHighMemoryPressure` PrometheusRules |
| `dashboards/` | Grafana dashboard: the util-vs-allocation gap (auto-provisioned via a `grafana_dashboard` ConfigMap) |
| `docs/` | Architecture, the cost narrative, the apply/demo/destroy runbook, and the postmortem |

## Quickstart

Prerequisites: an AWS account with the **G/VT instance quotas** raised (spot and/or
on-demand - a fresh account has these at 0), `aws`, `terraform`, `kubectl`, `helm`, and
the remote-state backend bootstrapped (see [`bootstrap.md`](bootstrap.md)).

```bash
cd terraform
export TF_VAR_grafana_admin_password='<something strong>'
terraform init
terraform apply                       # ~15 min (EKS control plane dominates)

aws eks update-kubeconfig --name gpu-observability-demo --region us-west-2
kubectl get nodes -l workload-type=gpu
kubectl get node -l workload-type=gpu \
  -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}{"\n"}'   # should print 1

kubectl apply -f ../manifests/vllm/
kubectl -n workloads rollout status deploy/vllm --timeout=10m      # cold start: model load

# watch the gap (the dashboard is already provisioned)
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
# open http://localhost:3000  ->  Dashboards  ->  GPU Utilization vs Allocation

kubectl apply -f ../manifests/loadgen/   # drive load, watch the gap open
```

Spot capacity is the default; if it is unfulfillable, apply on-demand with
`-var gpu_capacity_type=ON_DEMAND`. Full walkthrough, time-slicing demo, and teardown:
[`docs/runbook.md`](docs/runbook.md).

## Teardown

```bash
kubectl delete -f manifests/vllm/ -f manifests/loadgen/
cd terraform && terraform destroy
```

## Cost

Spot `g4dn.xlarge` ~\$0.16/hr (on-demand ~\$0.53/hr) + EKS control plane \$0.10/hr + NAT.
A same-day apply/demo/destroy is a few dollars. The GPU pool can be set to `min_size = 0`
to scale to zero between demos.

## Notes / honest scope

This is a platform-reliability project, not model engineering. It owns scheduling,
observability, capacity, and the cost signal around GPUs. Kernel-level CUDA work,
distributed-training communication (NCCL), and fabric tuning (InfiniBand/RDMA) are out
of scope by design.
</content>
