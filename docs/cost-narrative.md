# The cost narrative: allocation vs activity

This is the "so what" of the project - the thing a platform SRE is actually paid to
catch on a GPU fleet. Keep it in mind as the story to tell, not just a dashboard.

## The problem in one sentence

A GPU bills whether or not it does work, and the cluster's default view of "is it busy"
is wrong, so expensive cards sit allocated-but-idle and nobody sees it.

## Why the obvious metric lies

`DCGM_FI_DEV_GPU_UTIL` (the same number `nvidia-smi` prints) is the fraction of time at
least one kernel was resident on the GPU. It says nothing about how much of the card is
used. A single-threaded kernel touching one SM out of dozens reads as 100%. Alerting or
capacity-planning on this number systematically overstates how loaded a fleet is.

## The honest signal

The DCGM profiling counters measure real work:

- `DCGM_FI_PROF_GR_ENGINE_ACTIVE` - fraction of time the compute engine was active
- `DCGM_FI_PROF_PIPE_TENSOR_ACTIVE` - fraction of time the tensor cores were active
- `DCGM_FI_PROF_DRAM_ACTIVE` - memory-bandwidth activity (is it memory-bound?)
- `DCGM_FI_DEV_FB_USED` - framebuffer memory in use (a proxy for "a workload is resident")

"Allocated but idle" = framebuffer in use **and** engine activity near zero. That pod is
holding a card it isn't using.

## What it's worth

Rough order-of-magnitude, on-demand list price:

| GPU | ~\$/hr | One card idle 1 month | Ten cards idle 1 month |
|-----|-------:|----------------------:|-----------------------:|
| T4 (g4dn.xlarge) | ~0.53 | ~\$380 | ~\$3.8k |
| A10G (g5.xlarge) | ~1.00 | ~\$730 | ~\$7.3k |
| A100 (p4d, per GPU) | ~4+ | ~\$2.9k | ~\$29k |

A 20-30% allocated-but-idle rate is common on fleets that only watch `GPU_UTIL`. On A100s
that is five figures a month of nothing.

## What you do about it

1. **See it** - `gpu:allocated_but_idle:ratio` recording rule + the `GPUAllocatedButIdle`
   alert in `manifests/alerts/`.
2. **Repack** - if workloads are small and don't need isolation, time-slice (or MPS) so
   several share a card instead of each holding one. On A100/H100, MIG gives the same
   packing with hard isolation.
3. **Reclaim / right-size** - scale the GPU pool to zero when idle; move a workload that
   never saturates a card onto a smaller one.

The number to put in front of a hiring manager isn't "I deployed dcgm-exporter." It's
"I found the allocation-vs-activity gap and here's what closing it is worth."
