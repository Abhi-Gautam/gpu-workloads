#!/usr/bin/env bash
# Single-GPU pod + Volcano gang classroom checks.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONTEXT="${KUBE_CONTEXT:-kind-gpu-lab-local}"
kubectl_c() { kubectl --context "$CONTEXT" "$@"; }

echo "==> cluster GPU inventory"
kubectl_c get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\\.com/gpu,TAINTS:.spec.taints

echo "==> clean previous smoke objects"
kubectl_c -n gpu-lab delete pod single-gpu --ignore-not-found --wait=false
kubectl_c -n gpu-lab delete vcjob gang-sleep --ignore-not-found --wait=false 2>/dev/null \
  || kubectl_c -n gpu-lab delete job.batch.volcano.sh gang-sleep --ignore-not-found --wait=false 2>/dev/null \
  || true
# wait a beat for GPU free
sleep 3

echo "==> [1/3] single fake-GPU pod"
kubectl_c apply -f "$ROOT/deploy/examples/single-gpu-pod.yaml"
kubectl_c -n gpu-lab wait --for=condition=Ready pod/single-gpu --timeout=60s
kubectl_c -n gpu-lab logs single-gpu
phase="$(kubectl_c -n gpu-lab get pod single-gpu -o jsonpath='{.status.phase}')"
echo "    phase=${phase}"

echo "==> [2/3] with 1 GPU held, gang job should NOT fully run (only 1 GPU left)"
kubectl_c apply -f "$ROOT/deploy/examples/gang-sleep.yaml"
# give volcano a few seconds
sleep 8
echo "--- pods ---"
kubectl_c -n gpu-lab get pods -o wide
echo "--- vcjob ---"
kubectl_c -n gpu-lab get vcjob 2>/dev/null || kubectl_c -n gpu-lab get job.batch.volcano.sh || true
running="$(kubectl_c -n gpu-lab get pods -l lab=gang-sleep --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')"
pending="$(kubectl_c -n gpu-lab get pods -l lab=gang-sleep --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l | tr -d ' ')"
echo "    gang Running=${running} Pending=${pending} (expect Running=0 while single-gpu holds 1 GPU; both pending or job waiting)"
if [[ "$running" -ge 2 ]]; then
  echo "unexpected: gang fully running while single-gpu still holds a GPU" >&2
  exit 1
fi

echo "==> [3/3] free the held GPU → gang should run (2 pods)"
kubectl_c -n gpu-lab delete pod single-gpu --wait=true
deadline=$((SECONDS + 90))
while (( SECONDS < deadline )); do
  running="$(kubectl_c -n gpu-lab get pods -l lab=gang-sleep --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  succeeded="$(kubectl_c -n gpu-lab get pods -l lab=gang-sleep --field-selector=status.phase=Succeeded --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  echo "    Running=${running} Succeeded=${succeeded}"
  if [[ "$running" -ge 2 || "$succeeded" -ge 2 || $((running + succeeded)) -ge 2 ]]; then
    break
  fi
  sleep 3
done
kubectl_c -n gpu-lab get pods -o wide
if [[ "${running:-0}" -lt 2 && "${succeeded:-0}" -lt 2 && $(( ${running:-0} + ${succeeded:-0} )) -lt 2 ]]; then
  echo "gang did not reach 2 Running/Succeeded pods" >&2
  kubectl_c -n gpu-lab describe vcjob gang-sleep 2>/dev/null || true
  kubectl_c -n gpu-lab describe pods -l lab=gang-sleep 2>/dev/null | tail -80 || true
  exit 1
fi

echo
echo "SMOKE OK — device plugin allocatable + Volcano gang minAvailable behavior observed."
echo "Cleanup: kubectl --context ${CONTEXT} -n gpu-lab delete vcjob gang-sleep --ignore-not-found"
