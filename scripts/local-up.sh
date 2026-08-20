#!/usr/bin/env bash
# Bring up kind + fake GPU device plugin + Volcano. Idempotent-ish.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-gpu-lab-local}"
PLUGIN_IMAGE="${PLUGIN_IMAGE:-gpu-lab/fake-gpu-device-plugin:local}"
VOLCANO_CHART_VERSION="${VOLCANO_CHART_VERSION:-1.11.0}"

export AWS_PROFILE="${AWS_PROFILE:-}" # do not require AWS for local
cd "$ROOT"

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need kind
need kubectl
need helm
need docker

echo "==> kind cluster ${CLUSTER_NAME}"
if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  kind create cluster --config "$ROOT/deploy/local/kind/cluster.yaml"
else
  echo "    already exists"
  kind export kubeconfig --name "$CLUSTER_NAME" >/dev/null
fi
kubectl cluster-info --context "kind-${CLUSTER_NAME}" >/dev/null

echo "==> wait for nodes"
kubectl wait --for=condition=Ready nodes --all --timeout=180s

echo "==> build + load fake device plugin (${PLUGIN_IMAGE})"
docker build -t "$PLUGIN_IMAGE" "$ROOT/deploy/local/fake-gpu-device-plugin"
kind load docker-image "$PLUGIN_IMAGE" --name "$CLUSTER_NAME"

echo "==> Volcano (chart ${VOLCANO_CHART_VERSION}) before GPU taints"
# Workers must stay schedulable for volcano system pods. Optional GPU taints
# are a separate exercise (see docs/local-kind-lab.md) — apply only after
# patching volcano Deployments with nvidia.com/gpu tolerations.
helm repo add volcano-sh https://volcano-sh.github.io/helm-charts 2>/dev/null || true
helm repo update volcano-sh >/dev/null
helm upgrade --install volcano volcano-sh/volcano \
  --namespace volcano-system --create-namespace \
  --version "$VOLCANO_CHART_VERSION" \
  -f "$ROOT/deploy/local/volcano/values.yaml" \
  --wait --timeout 5m

echo "==> apply fake GPU device plugin DaemonSet"
kubectl apply -f "$ROOT/deploy/local/fake-gpu-device-plugin/daemonset.yaml"
kubectl -n kube-system rollout status ds/fake-gpu-device-plugin --timeout=120s

echo "==> wait until workers advertise nvidia.com/gpu"
deadline=$((SECONDS + 120))
ok=0
while (( SECONDS < deadline )); do
  ok=0
  while IFS= read -r line; do
    gpus="${line##* }"
    name="${line%% *}"
    if [[ "$gpus" == "1" ]]; then
      ok=$((ok + 1))
    fi
    echo "    ${name}: allocatable nvidia.com/gpu=${gpus}"
  done < <(kubectl get nodes -l role=gpu -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null || true)
  if [[ "$ok" -ge 2 ]]; then
    break
  fi
  sleep 2
done
if [[ "${ok:-0}" -lt 2 ]]; then
  echo "workers did not advertise nvidia.com/gpu=1 in time" >&2
  kubectl -n kube-system get pods -l app=fake-gpu-device-plugin -o wide || true
  kubectl -n kube-system logs -l app=fake-gpu-device-plugin --tail=50 || true
  exit 1
fi

echo "==> namespace gpu-lab"
kubectl apply -f "$ROOT/deploy/examples/namespace.yaml"

echo
echo "Local GPU lab is up (FAKE nvidia.com/gpu)."
echo "  kubectl get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\\.com/gpu,TAINTS:.spec.taints"
echo "  ./scripts/local-smoke.sh"
echo "  ./scripts/local-down.sh"
