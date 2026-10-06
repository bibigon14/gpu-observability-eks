# Runbook - apply, demo, destroy

## 0. Prerequisites

- G/VT quotas raised in the target region (spot `L-3819A6DF`, on-demand `L-DB2E81BA`;
  a fresh account has both at 0 vCPU - request before you start, approval can take hours):
  ```bash
  aws service-quotas get-service-quota --service-code ec2 --quota-code L-3819A6DF --region us-west-2 \
    --query 'Quota.Value'
  ```
- Remote state bootstrapped - see [`../bootstrap.md`](../bootstrap.md).
- Tools: `aws`, `terraform >= 1.7`, `kubectl`, `helm`.

## 1. Apply

```bash
cd terraform
export TF_VAR_grafana_admin_password='<strong-password>'
terraform init
terraform apply        # ~15 min; EKS control plane is the long pole
```

If spot capacity is unavailable the GPU node won't join. Fall back to on-demand:
```bash
terraform apply -var gpu_capacity_type=ON_DEMAND
```

## 2. Verify the GPU is schedulable

```bash
aws eks update-kubeconfig --name gpu-observability-demo --region us-west-2
kubectl get nodes -l workload-type=gpu
kubectl -n gpu-operator get pods                    # operator, device-plugin, gfd, dcgm-exporter Running
kubectl describe node -l workload-type=gpu | grep nvidia.com/gpu
#   Allocatable: nvidia.com/gpu: 1   <- the device plugin advertised the card
```

Common failure: pod stuck `Pending` with `Insufficient nvidia.com/gpu`. Check the device
plugin is running on the GPU node and the node actually advertises the resource (line
above). Nine times out of ten it's the plugin not up or a taint/label mismatch, not real
capacity.

## 3. Serve the model

```bash
kubectl apply -f ../manifests/vllm/
kubectl -n workloads rollout status deploy/vllm --timeout=10m
```
First start is slow: the image is large and the model downloads into VRAM (cold start).
The readiness probe allows for it.

## 4. Watch the gap (the point of the project)

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
# http://localhost:3000  (admin / $TF_VAR_grafana_admin_password)
# Dashboard: GPU / "GPU Utilization vs Allocation"
```

**Idle state** (model loaded, no traffic): framebuffer memory is high (card allocated),
`GR_ENGINE_ACTIVE` near zero. After 15m `GPUAllocatedButIdle` fires. **This is the money
shot** - screenshot it.

**Under load:**
```bash
kubectl apply -f ../manifests/loadgen/
kubectl -n workloads logs -f job/vllm-loadgen
```
Engine and tensor activity rise, KV-cache usage climbs, `GPU_UTIL` pins near 100% while
`GR_ENGINE_ACTIVE` tells the real story. Screenshot the contrast.

## 5. (Optional) Time-slicing demo

Show software GPU sharing on the T4 (no MIG):
```bash
kubectl apply -f ../manifests/time-slicing/time-slicing-config.yaml
kubectl -n gpu-operator patch clusterpolicy cluster-policy --type merge \
  -p '{"spec":{"devicePlugin":{"config":{"name":"time-slicing-config","default":"any"}}}}'
# node now advertises nvidia.com/gpu: 4
kubectl describe node -l workload-type=gpu | grep nvidia.com/gpu
```
Scale vLLM to 2 replicas and watch both land on one physical card. Note: no memory or
fault isolation - this is for non-critical sharing only.

## 6. (Optional) Add SM_ACTIVE

```bash
kubectl apply -f ../manifests/dcgm/configmap-custom-metrics.yaml
kubectl -n gpu-operator patch clusterpolicy cluster-policy --type merge \
  -p '{"spec":{"dcgmExporter":{"config":{"name":"dcgm-custom-metrics"}}}}'
kubectl -n gpu-operator rollout restart ds -l app=nvidia-dcgm-exporter
```

## 7. Destroy

```bash
kubectl delete -f ../manifests/vllm/ -f ../manifests/loadgen/ --ignore-not-found
cd terraform && terraform destroy
```
Confirm nothing GPU-shaped is left running:
```bash
aws ec2 describe-instances --region us-west-2 \
  --filters "Name=instance-type,Values=g4dn.xlarge" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId'
```
