#!/usr/bin/env bash
# Remove the lab resources and (optionally) the kind cluster.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-inventory-lab}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

kubectl delete -f "$ROOT/k8s/" --ignore-not-found
if [[ "${1:-}" == "--delete-cluster" ]]; then
  kind delete cluster --name "$CLUSTER_NAME"
fi
