#!/usr/bin/env bash
# Runs every lab demonstration end-to-end and prints labelled evidence.
# Output is also saved to evidence/demo-output.txt.
#
# Prerequisite: the application is deployed (scripts/setup.sh).
# Pod names are discovered dynamically from the label app=inventory - nothing is hard-coded.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/evidence/demo-output.txt"
mkdir -p "$ROOT/evidence"
exec > >(tee "$OUT") 2>&1

SERVICE_URL="http://inventory-service:8080/inventory"
REQUESTS="${REQUESTS:-20}"

section() { printf '\n==================================================================\n%s\n==================================================================\n' "$*"; }
# Print a command exactly as typed, then run it.
run() { printf '\n$ %s\n' "$*"; eval "$@"; }
fail() { echo "DEMO CHECK FAILED: $*" >&2; exit 1; }

inventory_pods() { kubectl get pods -l app=inventory --field-selector=status.phase=Running \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort; }

# Sends N separate requests through the Service from the client Pod.
# Every curl is a new TCP connection, so kube-proxy picks a backend per request.
burst() {
  local n="$1"
  printf '\n$ kubectl exec client -- sh -c '\''for i in $(seq 1 %s); do printf "request %%02d -> " $i; curl -s %s | grep -o "\\"pod\\": \\"[^\\"]*\\""; done'\''\n' "$n" "$SERVICE_URL"
  BURST_OUTPUT="$(kubectl exec client -- sh -c "for i in \$(seq 1 $n); do printf 'request %02d -> ' \$i; curl -s $SERVICE_URL | grep -o '\"pod\": \"[^\"]*\"'; done")"
  echo "$BURST_OUTPUT"
  echo
  echo "Requests handled per Pod:"
  echo "$BURST_OUTPUT" | grep -o 'inventory-[a-z0-9-]*' | sort | uniq -c
}
count_for() { echo "$BURST_OUTPUT" | grep -c "\"$1\"" || true; }

# Lists every endpoint in the Service's EndpointSlices with its ready condition.
SLICE_CMD="kubectl get endpointslices -l kubernetes.io/service-name=inventory-service -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}{\"  ip=\"}{.addresses[0]}{\"  ready=\"}{.conditions.ready}{\"\\n\"}{end}'"
slice_endpoints() { eval "$SLICE_CMD" | sort; }
# Polls until the EndpointSlice reports the expected ready state for a Pod
# (the EndpointSlice controller updates shortly after the Pod condition changes).
wait_slice() {
  local pod="$1" want="$2"
  for _ in $(seq 1 30); do
    slice_endpoints | grep -q "^$pod .*ready=$want$" && return 0
    sleep 1
  done
  fail "EndpointSlice never showed $pod ready=$want"
}

section "0. ENVIRONMENT"
run kubectl version
run kubectl config current-context
run kubectl get nodes -o wide

section "1. DEPLOYMENT: 2 Inventory replicas, 1 Service, 1 client"
run kubectl rollout status deployment/inventory --timeout=120s
run kubectl get deployments -o wide
run kubectl get pods -o wide
run kubectl get service inventory-service -o wide
run "kubectl get endpointslices -l kubernetes.io/service-name=inventory-service"
[[ "$(inventory_pods | wc -l | tr -d ' ')" == "2" ]] || fail "expected 2 Inventory Pods"

section "2. SERVICE DISCOVERY: the client only knows the Service DNS name"
run "kubectl get pod client -o jsonpath='{.spec.containers[0].env}'; echo"
run kubectl exec client -- nslookup inventory-service.default.svc.cluster.local
run "kubectl exec client -- curl -sv $SERVICE_URL 2>&1 | grep -E 'Connected to|\"pod\"' | sed 's/, \"items\".*//'"
echo
echo "Service ClusterIP: $(kubectl get svc inventory-service -o jsonpath='{.spec.clusterIP}')"
echo "Inventory Pod IPs: $(kubectl get pods -l app=inventory -o jsonpath='{.items[*].status.podIP}')"
echo "-> curl connected to the Service ClusterIP (resolved from the name), not to a Pod IP."

section "3. LOAD DISTRIBUTION: $REQUESTS requests to $SERVICE_URL"
PODS=($(inventory_pods))
POD_A="${PODS[0]}"; POD_B="${PODS[1]}"
echo "Inventory Pod A: $POD_A"
echo "Inventory Pod B: $POD_B"
burst "$REQUESTS"
(( $(count_for "$POD_A") > 0 && $(count_for "$POD_B") > 0 )) || fail "both replicas should have served requests"
echo "-> Both replicas answered requests sent to the single Service name."

section "4a. READINESS - BEFORE FAILURE"
run kubectl get pods -l app=inventory -o wide
run "$SLICE_CMD"

section "4b. READINESS - TRIGGER FAILURE ON $POD_A ONLY"
run "kubectl exec $POD_A -- curl -s -X POST http://localhost:8080/readiness/fail"
run kubectl wait --for=condition=Ready=false "pod/$POD_A" --timeout=30s
wait_slice "$POD_A" false

section "4c. READINESS - $POD_A IS RUNNING BUT NOT READY (0/1, 0 restarts)"
run kubectl get pods -l app=inventory -o wide
run "kubectl get pod $POD_A -o jsonpath='phase={.status.phase}  ready={.status.containerStatuses[0].ready}  restarts={.status.containerStatuses[0].restartCount}'; echo"
run "kubectl exec $POD_A -- curl -s -o /dev/null -w 'GET /health -> %{http_code}\n' http://localhost:8080/health"
run "kubectl exec $POD_A -- curl -s -o /dev/null -w 'GET /ready  -> %{http_code}\n' http://localhost:8080/ready"
run "kubectl get events --field-selector involvedObject.name=$POD_A,reason=Unhealthy -o custom-columns=TYPE:.type,REASON:.reason,MESSAGE:.message | head -3"
[[ "$(kubectl get pod "$POD_A" -o jsonpath='{.status.phase}')" == "Running" ]] || fail "$POD_A should still be Running"

section "4d. READINESS - SERVICE ENDPOINTS EXCLUDE $POD_A"
run kubectl get endpoints inventory-service -o wide
run "$SLICE_CMD"

section "4e. READINESS - TRAFFIC DURING FAILURE ($REQUESTS requests through the Service)"
burst "$REQUESTS"
[[ "$(count_for "$POD_A")" == "0" ]] || fail "unready Pod $POD_A received traffic"
(( $(count_for "$POD_B") == REQUESTS )) || fail "ready Pod $POD_B should have served every request"
echo "-> All $REQUESTS requests were served by $POD_B; unready $POD_A received none."

section "4f. READINESS - RESTORE $POD_A"
run "kubectl exec $POD_A -- curl -s -X POST http://localhost:8080/readiness/restore"
run kubectl wait --for=condition=Ready "pod/$POD_A" --timeout=30s
wait_slice "$POD_A" true
run kubectl get pods -l app=inventory -o wide
run kubectl get endpoints inventory-service -o wide
run "$SLICE_CMD"

section "4g. READINESS - BOTH REPLICAS RECEIVE TRAFFIC AGAIN"
burst "$REQUESTS"
(( $(count_for "$POD_A") > 0 )) || fail "restored Pod $POD_A received no traffic"
echo "-> Restored Pod $POD_A is serving Service traffic again (restart count unchanged)."
run "kubectl get pods -l app=inventory -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount"
run "kubectl logs $POD_A | grep -E 'listening|readiness'"

section "5a. POD FAILURE - BEFORE DELETION"
LOG_START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
OLD_PODS=($(inventory_pods))
VICTIM="$POD_B"
SVC_BEFORE="$(kubectl get svc inventory-service -o jsonpath='name={.metadata.name} clusterIP={.spec.clusterIP} uid={.metadata.uid}')"
run kubectl get pods -l app=inventory -o wide
run kubectl get service inventory-service -o wide
echo "Service identity before: $SVC_BEFORE"
echo "Pod selected for deletion: $VICTIM ($(kubectl get pod "$VICTIM" -o jsonpath='{.status.podIP}'))"

section "5b. POD FAILURE - DELETE $VICTIM"
run kubectl delete pod "$VICTIM"
run kubectl get pods -l app=inventory -o wide

section "5c. POD FAILURE - DEPLOYMENT/REPLICASET CREATES A REPLACEMENT"
run kubectl rollout status deployment/inventory --timeout=120s
run kubectl wait --for=condition=Ready pod -l app=inventory --timeout=120s
run kubectl get pods -l app=inventory -o wide
run kubectl get deployment inventory
RS="$(kubectl get rs -l app=inventory -o jsonpath='{.items[0].metadata.name}')"
run "kubectl get events --field-selector involvedObject.name=$RS,reason=SuccessfulCreate --sort-by=.lastTimestamp -o custom-columns=REASON:.reason,OBJECT:.involvedObject.name,MESSAGE:.message | tail -1"

section "5d. POD FAILURE - OLD VS NEW POD IDENTITY"
NEW_PODS=($(inventory_pods))
NEW_POD="$(comm -13 <(printf '%s\n' "${OLD_PODS[@]}") <(printf '%s\n' "${NEW_PODS[@]}"))"
[[ -n "$NEW_POD" && "$NEW_POD" != "$VICTIM" ]] || fail "no newly named replacement Pod found"
kubectl get pod "$VICTIM" >/dev/null 2>&1 && fail "deleted Pod $VICTIM still exists"
echo "Pods before deletion : ${OLD_PODS[*]}"
echo "Pods after deletion  : ${NEW_PODS[*]}"
echo "Deleted Pod          : $VICTIM"
echo "Replacement Pod      : $NEW_POD ($(kubectl get pod "$NEW_POD" -o jsonpath='{.status.podIP}'))"
run "kubectl get pod $VICTIM 2>&1 || true"

section "5e. POD FAILURE - SERVICE UNCHANGED, CLIENT STILL WORKS"
SVC_AFTER="$(kubectl get svc inventory-service -o jsonpath='name={.metadata.name} clusterIP={.spec.clusterIP} uid={.metadata.uid}')"
run kubectl get service inventory-service -o wide
echo "Service identity before: $SVC_BEFORE"
echo "Service identity after : $SVC_AFTER"
[[ "$SVC_BEFORE" == "$SVC_AFTER" ]] || fail "Service changed"
echo "-> Same Service name, ClusterIP and UID. Client configuration was not modified."
run "$SLICE_CMD"
burst "$REQUESTS"
(( $(count_for "$NEW_POD") > 0 )) || fail "replacement Pod received no traffic"
(( $(count_for "$VICTIM") == 0 )) || fail "deleted Pod still answered"
echo "-> Replacement $NEW_POD is serving requests through the unchanged Service."

section "5f. CLIENT BACKGROUND LOOP ACROSS THE DELETION (kubectl logs client)"
# Short pause so the client's 1-request-per-second loop records a few more
# requests after the replacement became ready (no Kubernetes state to wait on here).
sleep 5
echo "Pod deleted: $VICTIM   Replacement: $NEW_POD"
run "kubectl logs client --since-time=$LOG_START"

section "DEMO COMPLETE - ALL CHECKS PASSED"
