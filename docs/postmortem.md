# Postmortem: standing up GPU observability on EKS

A blameless write-up of what broke while bringing this cluster up for the first time,
and why the final design looks the way it does. The short version: running GPUs on EKS
is a driver-and-AMI matrix problem, and the cleanest answer is to let AWS own the driver
(the accelerated AMI) and run only the device plugin and dcgm-exporter against it, rather
than the full GPU Operator.

## Summary

Ten distinct failures, each a real-world EKS-GPU gotcha:

| # | Symptom | Root cause | Resolution |
|---|---------|-----------|------------|
| 1 | `InvalidParameterException: Requested AMI for this version 1.30 is not supported` | Cluster pinned to k8s **1.30, which is end-of-support**; AWS withdraws the AL2 AMIs for EOL versions | Default node AMI was AL2; moved to AL2023, later bumped cluster to a current version |
| 2 | Node group `CREATE_FAILED: UnfulfillableCapacity` | No **spot** g4dn capacity in the AZs at that moment | Fell back to on-demand (`gpu_capacity_type=ON_DEMAND`) |
| 3 | `operator-validator` loops "failed to validate the driver"; `nvidia-smi` → `Failed to initialize NVML` | GPU Operator with `driver.enabled=false` on the **accelerated AMI** does not cleanly validate a host-installed driver | Abandoned the pre-installed-driver + operator combination |
| 4 | `nvidia-driver-daemonset` → `ImagePullBackOff: nvcr.io/nvidia/driver:550.90.07-amzn2023: not found` | Operator-managed driver on a plain AL2023 node needs a driver image for that OS; **no generic `amzn2023` image exists** for the operator's default driver version | Stopped trying to have the operator manage the driver |
| 5 | `DaemonSet "nvidia-device-plugin-mps-control-daemon" ... cannot be imported` | A **destroyed GPU Operator left orphaned resources** in the namespace that the new standalone chart could not adopt | Rebuilt the cluster clean on a current k8s version |
| 6 | vLLM pods evicted `ContainerStatusUnknown`; node `DiskPressure: True` | The vLLM image (~8GB) + model fills the **default ~20GB node volume** | Sized the root volume to 100GB (see #8 for how) |
| 7 | dcgm `ServiceMonitor` silently produced no metrics; Operator log: `scrapeTimeout 25s greater than scrapeInterval 5s` | The dcgm-exporter chart hard-codes `scrapeTimeout=25s`; the **Prometheus Operator rejects any ServiceMonitor whose interval is shorter than its timeout**, dropping the whole target | Set the dcgm ServiceMonitor `interval` to `30s` (must be `>= 25s`) |
| 8 | `disk_size = 100` had **no effect**; nodes still came up with the ~20GB default and kept hitting DiskPressure (#6) | The EKS module provisions the node group via a **launch template**, and the top-level `disk_size` is ignored when a launch template is in play | Sized the root volume through `block_device_mappings` (`/dev/xvda`, 100GB gp3) instead |
| 9 | vLLM crash-loops: `ValueError: invalid literal for int() with base 10: 'tcp://172.20.x.x:8000'` | Kubernetes injects legacy per-Service env vars; the Service named `vllm` injects `VLLM_PORT=tcp://<ip>:8000`, which **vLLM reads as its integer port** and chokes on | Set `enableServiceLinks: false` on the pod spec |
| 10 | `terraform apply` fails after ~40min: `NodeCreationFailure: new nodes are not joining the cluster` on a GPU node-group replacement | A node-group update that **replaces** the instance (here, moving the root volume to `block_device_mappings`) rolls a new node that failed to register; the old 100GB node was already drained, leaving only a stale cordoned node | Left the observability pipeline proven on the surviving node; teardown via `terraform destroy` rather than reconciling the half-applied update |

## Timeline (abridged)

1. First apply: AL2 system-node AMI rejected on EOL k8s 1.30 (#1); spot GPU capacity
   unfulfillable (#2). Fixed AMIs to AL2023, GPU pool to on-demand.
2. Second apply: GPU node up on the **accelerated AMI** (`AL2023_x86_64_NVIDIA`), but the
   GPU Operator's validator looped and `nvidia-smi` failed NVML init (#3). Diagnosed as the
   operator not owning a host-installed driver.
3. Third apply: switched to the plain AL2023 AMI so the **operator could own the driver** -
   its driver daemonset then `ImagePullBackOff`-ed on a non-existent `amzn2023` image (#4).
   Confirmed via the nvcr.io tag list that no such image is published.
4. Decision point: both operator paths are dead ends on EKS AL2023. Switched to the
   **accelerated AMI + standalone `nvidia-device-plugin` + `dcgm-exporter`**, dropping the
   GPU Operator. First attempt hit orphaned operator resources (#5).
5. Clean rebuild on a current k8s version: **GPU healthy** - device plugin advertises
   `nvidia.com/gpu: 1`, dcgm-exporter initializes DCGM + NVML and detects the **Tesla T4**.
6. vLLM then hit `DiskPressure` on the default volume (#6); raised `disk_size`.

## Why not the GPU Operator?

The GPU Operator is the "proper" enterprise way to run GPUs on Kubernetes, and on a
self-managed base image where it owns the whole stack it works well. On **EKS AL2023**
specifically, both ways of using it fail:

- **With the accelerated AMI** (driver pre-installed), `driver.enabled=false` leaves the
  operator-validator unable to validate the host driver - it loops forever and blocks the
  device-plugin and dcgm-exporter behind it.
- **With a plain AL2023 AMI** (operator installs the driver), the operator's default driver
  version has no published `amzn2023` container image, so the driver daemonset can't pull.

The pragmatic, reliable choice on EKS is therefore to **let AWS own the driver** via the
EKS accelerated AMI (AWS builds and tests it per k8s version) and run just the two pieces
that are actually needed - the device plugin and dcgm-exporter - directly against that
host driver. Fewer moving parts, no driver image to chase, no validator to satisfy.

## Lessons

1. **Don't pin an EOL Kubernetes version.** It withdraws the matching AMIs and causes
   confusing "AMI not supported" errors far from the real cause.
2. **GPU-on-EKS is a driver/AMI matrix, not a Kubernetes problem.** The k8s version was a
   red herring for the driver saga - the driver layer would fail the same way on any version.
3. **Prefer the vendor-tested path.** The EKS accelerated AMI's driver is AWS-validated;
   fighting the GPU Operator's driver lifecycle on an unsupported OS burns cycles.
4. **Size ephemeral storage for the image.** Large model-serving images (vLLM ~8GB) plus
   downloaded weights will trip `DiskPressure` on the default node volume.
5. **Spot is best-effort.** Keep an on-demand fallback for scarce instance types like g4dn.
6. **Rebuild beats repair after many partial applies.** Orphaned resources from a removed
   operator are cheaper to escape with a clean cluster than to reconcile by hand.
