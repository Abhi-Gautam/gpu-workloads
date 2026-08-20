# Local kind lab (fake GPU)

Teaches the **Kubernetes device-plugin contract** and **Volcano gang scheduling** on a Mac without NVIDIA hardware. This is not the destination lab (that is EKS + real T4). Same resource name (`nvidia.com/gpu`) so pod YAML transfers.

## What is real vs fake

| Real | Fake |
|---|---|
| kind multi-node cluster | silicon / CUDA / `nvidia-smi` |
| kubelet device-plugin gRPC registration | host driver / toolkit |
| node `allocatable.nvidia.com/gpu` | EKS AMI / GPU Operator |
| default scheduler packing by extended resource | Spot reclaim |
| Volcano `minAvailable` gang block/run | production IAM / cost |

## Prereqs

- Docker Desktop running
- `kind`, `kubectl`, `helm` (scripts assume these on PATH)

## Commands

```bash
cd /Volumes/mac-devlopment/personal-projects/gpu-workloads
./scripts/local-up.sh      # ~few minutes first time (image build + helm)
./scripts/local-smoke.sh   # single GPU + gang Pending→Running
./scripts/local-down.sh    # delete kind cluster
```

## Observe yourself

```bash
# After up:
kubectl get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\\.com/gpu,TAINTS:.spec.taints

# Plugin logs (registration path):
kubectl -n kube-system logs -l app=fake-gpu-device-plugin --tail=50

# Hold one GPU, watch second pod Pending:
kubectl -n gpu-lab apply -f deploy/examples/single-gpu-pod.yaml
kubectl -n gpu-lab run hog2 --image=busybox:1.36 --restart=Never \
  --overrides='{"spec":{"tolerations":[{"key":"nvidia.com/gpu","operator":"Exists","effect":"NoSchedule"}],"containers":[{"name":"c","image":"busybox:1.36","command":["sleep","3600"],"resources":{"limits":{"nvidia.com/gpu":"1"}}}]}}'
kubectl -n gpu-lab get pods -o wide
```

## Optional: GPU taints (EKS-shaped)

Default `local-up` does **not** taint workers — Volcano system pods need somewhere to land, and kind has no separate untainted pool.

After Volcano is healthy you can try:

```bash
kubectl taint nodes -l role=gpu nvidia.com/gpu=true:NoSchedule --overwrite
# Then either tolerate on volcano Deployments, or leave taints off for local.
```

Example pods already include the `nvidia.com/gpu` toleration so they keep working once you taint.

## Mental model

1. DaemonSet plugin opens a unix socket under `/var/lib/kubelet/device-plugins`.
2. It **Register**s with kubelet: resource name `nvidia.com/gpu`.
3. **ListAndWatch** streams healthy device IDs (`fake-gpu-0`, …).
4. kubelet publishes allocatable count on the Node object.
5. Pods request `limits.nvidia.com/gpu: 1` → scheduler binds only if count remains.
6. On bind, kubelet calls **Allocate** → we inject env (`FAKE_NVIDIA_VISIBLE_DEVICES`) only.
7. Volcano adds **all-or-nothing** across tasks (`minAvailable: 2`).

When AWS G/VT quota clears, swap the fake DaemonSet for the real NVIDIA plugin on `g4dn` nodes; keep Volcano Job shapes.
