#!/usr/bin/env bash
set -euo pipefail
CLUSTER_NAME="${CLUSTER_NAME:-gpu-lab-local}"
command -v kind >/dev/null || { echo "missing kind" >&2; exit 1; }
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  kind delete cluster --name "$CLUSTER_NAME"
  echo "deleted kind cluster ${CLUSTER_NAME}"
else
  echo "cluster ${CLUSTER_NAME} not found"
fi
