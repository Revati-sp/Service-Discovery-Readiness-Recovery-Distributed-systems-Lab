#!/usr/bin/env bash
# Create a kind cluster, build the Inventory image, load it into kind and deploy all manifests.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-inventory-lab}"
IMAGE="inventory:1.0"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  kind create cluster --name "$CLUSTER_NAME" --wait 120s
fi
kubectl config use-context "kind-$CLUSTER_NAME"

docker build -t "$IMAGE" "$ROOT/app"
kind load docker-image "$IMAGE" --name "$CLUSTER_NAME"

kubectl apply -f "$ROOT/k8s/"
kubectl rollout status deployment/inventory --timeout=120s
kubectl wait --for=condition=Ready pod/client --timeout=120s
kubectl get deployments,pods,services -o wide
