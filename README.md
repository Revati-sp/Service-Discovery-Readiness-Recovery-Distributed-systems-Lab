# Kubernetes Service Discovery, Readiness & Pod Recovery Lab

## Overview

This repository deploys a small **Inventory** HTTP service on Kubernetes (kind) and demonstrates service discovery, readiness, and Pod replacement:

* **Deployment `inventory`**: exactly **2 replicas**, with a readiness probe on `/ready` and a liveness probe on `/health`.
* **Service `inventory-service`**: a `ClusterIP` Service on port 8080 that selects `app=inventory`.
* **Pod `client`**: exactly **1 client**. It calls only `http://inventory-service:8080/inventory` and never uses a Pod IP.

Every Inventory response includes the **name of the Pod that handled it** (`"pod": "<pod-name>"`). This is how the evidence below proves which replica served each request.

> All terminal output in this README is **real output** from `scripts/setup.sh` and `scripts/run-demo.sh`, run on a kind cluster (Kubernetes v1.37.0, kubectl v1.37.1, Docker Desktop on macOS arm64). The unedited full transcript is in [`evidence/demo-output.txt`](evidence/demo-output.txt) and [`evidence/setup-output.txt`](evidence/setup-output.txt). Pod names and IPs will differ when you run it yourself.

### Requirement → Evidence Map

| Assignment requirement | Where to find it | Key evidence |
|---|---|---|
| Deployment with 2 Inventory replicas | [Verify Deployment](#verify-deployment) · [`k8s/inventory-deployment.yaml`](k8s/inventory-deployment.yaml) | `inventory   2/2` |
| Service exposing the replicas | [Verify Deployment](#verify-deployment) · [`k8s/inventory-service.yaml`](k8s/inventory-service.yaml) | `inventory-service   ClusterIP   10.96.37.255`; EndpointSlice lists both Pod IPs |
| 1 client | [Verify Deployment](#verify-deployment) · [`k8s/client.yaml`](k8s/client.yaml) | a single `client` Pod |
| Both Pods running | [Verify Deployment](#verify-deployment) | both Inventory Pods `1/1 Running` |
| Client reaches Inventory by Service name | [Verify Kubernetes Service Discovery](#verify-kubernetes-service-discovery) | `Connected to inventory-service (10.96.37.255)`, which is the Service IP, not a Pod IP |
| Requests reach more than one replica | [Demonstrate Traffic Across Both Replicas](#demonstrate-traffic-across-both-replicas) | 20 requests: `cz9lg` 8, `k2qrz` 12 |
| Readiness probe added | [Readiness Probe Demonstration](#readiness-probe-demonstration) | `readinessProbe` on `/ready`; `Readiness probe failed ... 503` event |
| Unready Pod is still running | [Verify Pod Is Running but Unready](#verify-pod-is-running-but-unready) | `cz9lg   0/1   Running   0` restarts |
| Unready Pod stops receiving traffic | [Verify Service Traffic Avoids Unready Pod](#verify-service-traffic-avoids-unready-pod) | EndpointSlice `ready=false`; 0 of 20 requests to `cz9lg` |
| Other ready Pod keeps serving | [Verify Service Traffic Avoids Unready Pod](#verify-service-traffic-avoids-unready-pod) | 20 of 20 requests served by `k2qrz` |
| Readiness restored and Pod gets traffic again | [Restore Readiness](#restore-readiness) · [Verify Both Replicas Receive Traffic Again](#verify-both-replicas-receive-traffic-again) | `1/1 Running`; `cz9lg` serves 10 of 20 |
| Pod deleted and replacement created | [Delete One Pod](#delete-one-pod) · [Kubernetes Creates Replacement](#kubernetes-creates-replacement) | `Created pod: inventory-768b4699c8-qxvcs` |
| New Pod has a different name | [Compare Old and New Pod Identity](#compare-old-and-new-pod-identity) | `k2qrz` (deleted) → `qxvcs` (new) |
| Service name unchanged | [Verify Service Still Works](#verify-service-still-works) | same name, ClusterIP and UID before and after |
| Client keeps communicating through the Service | [Verify Service Still Works](#verify-service-still-works) | 20 of 20 requests succeed; client log has no failures across the deletion |
| Deployment instructions | [Build the Inventory Image](#build-the-inventory-image) · [Deploy](#deploy) | exact commands, plus `scripts/setup.sh` |
| Architecture diagram | [Architecture](#architecture) | Mermaid and plain-text diagrams |
| Reflection (3–5 sentences) | [Reflection](#reflection) | 4 sentences |

---

## Architecture

```mermaid
flowchart TB
    C["client Pod<br/>(curlimages/curl)<br/>INVENTORY_URL=http://inventory-service:8080/inventory"]
    DNS["Cluster DNS (CoreDNS)<br/>inventory-service → 10.96.37.255"]
    S{{"Service: inventory-service<br/>type ClusterIP · port 8080<br/>selector app=inventory"}}
    A["Inventory Pod A<br/>inventory-…-cz9lg<br/>READY 1/1"]
    B["Inventory Pod B<br/>inventory-…-k2qrz<br/>READY 1/1"]
    D["Deployment inventory<br/>replicas: 2<br/>(ReplicaSet keeps 2 Pods)"]

    C -- "1. resolve name" --> DNS
    C -- "2. HTTP GET /inventory" --> S
    S -- "ready endpoint" --> A
    S -- "ready endpoint" --> B
    D -. manages .-> A
    D -. manages .-> B
```

**While a Pod is unready**, the readiness probe on `/ready` fails, the endpoint is marked `ready=false`, and the Service routes only to the remaining ready Pod. The unready Pod keeps running and is **not restarted**:

```mermaid
flowchart LR
    C["client Pod"] -- "http://inventory-service:8080" --> S{{"inventory-service"}}
    S -- "traffic" --> B["Pod B · READY 1/1 · Running"]
    S -. "✗ no traffic (endpoint ready=false)" .-> A["Pod A · READY 0/1 · Running<br/>/ready → 503, /health → 200"]
```

Plain-text version of the same architecture:

```
            client Pod  (exactly 1)
                 │  HTTP  http://inventory-service:8080/inventory
                 ▼
     ┌──────────────────────────────┐
     │ Service: inventory-service   │  stable DNS name + ClusterIP
     │ selector: app=inventory      │  routes only to READY Pods
     └──────────────┬───────────────┘
           ┌────────┴────────┐
           ▼                 ▼
   Inventory Pod A     Inventory Pod B     ◄── Deployment "inventory", replicas: 2
   READY 1/1           READY 1/1
```

---

## Repository Structure

```
.
├── app/
│   ├── server.py                  # Inventory HTTP service (Python standard library only)
│   ├── Dockerfile                 # python:3.12-alpine + curl, non-root user
│   └── .dockerignore
├── k8s/
│   ├── inventory-deployment.yaml  # Deployment: 2 replicas, readiness + liveness probes
│   ├── inventory-service.yaml     # ClusterIP Service "inventory-service"
│   └── client.yaml                # The single client Pod (calls the Service by name)
├── scripts/
│   ├── setup.sh                   # create kind cluster → build image → load into kind → deploy
│   ├── run-demo.sh                # runs every demonstration with self-checks and saves the evidence
│   └── cleanup.sh                 # delete the resources (optionally the cluster)
├── evidence/
│   ├── setup-output.txt           # real output of scripts/setup.sh
│   └── demo-output.txt            # real output of scripts/run-demo.sh
└── README.md
```

---

## Prerequisites

The Kubernetes environment used is **kind** (Kubernetes in Docker). All commands below are for kind.

| Tool | Version used | Install (macOS) |
|---|---|---|
| Docker Desktop | 28.5.1 | https://www.docker.com/products/docker-desktop/ (must be running) |
| kind | v0.33.0 | `brew install kind` |
| kubectl | v1.37.1 | `brew install kubectl` |

Use a kubectl within one minor version of the cluster (kind v0.33 creates a v1.37 cluster), otherwise kubectl prints a version-skew warning.

---

## Application Endpoints

`app/server.py` listens on port **8080**.

| Method | Path | Purpose | Response |
|---|---|---|---|
| GET | `/` or `/inventory` | Normal application endpoint | `200` JSON with `service`, **`pod`**, `pod_ip`, `node`, `message`, `items` |
| GET | `/health` | Liveness probe. Reports only whether the process is alive. **Not** affected by readiness. | `200` |
| GET | `/ready` | Readiness probe | `200` when ready, **`503`** after `/readiness/fail` |
| POST | `/readiness/fail` | Makes **this Pod** report not-ready. The process keeps running. | `200` |
| POST | `/readiness/restore` | Makes **this Pod** report ready again | `200` |

Example response from `/inventory`:

```json
{"service": "inventory", "pod": "inventory-768b4699c8-k2qrz", "pod_ip": "10.244.0.19", "node": "inventory-lab-control-plane", "message": "Inventory request handled successfully", "items": [{"sku": "SKU-1001", "name": "Keyboard", "quantity": 42}, ...]}
```

`pod`, `pod_ip` and `node` are injected through the Kubernetes **Downward API** (`metadata.name`, `status.podIP`, `spec.nodeName`), so each replica reports its own identity.

**Readiness vs. liveness.** The readiness flag is held in memory, and `/readiness/fail` changes only what `/ready` returns. `/health` (the liveness probe) always returns 200 while the process is alive. Failing readiness therefore removes the Pod from Service traffic, but Kubernetes never restarts it.

---

## Build the Inventory Image

kind nodes cannot see images in your local Docker daemon, so the image is built locally and then **loaded into the kind node**. The Deployment uses `image: inventory:1.0` with `imagePullPolicy: IfNotPresent`, so Kubernetes uses the loaded image and does not pull from a registry.

```bash
kind create cluster --name inventory-lab --wait 120s
kubectl config use-context kind-inventory-lab

docker build -t inventory:1.0 app/
kind load docker-image inventory:1.0 --name inventory-lab
```

## Deploy

```bash
kubectl apply -f k8s/
kubectl rollout status deployment/inventory --timeout=120s
kubectl wait --for=condition=Ready pod/client --timeout=120s
```

**Shortcut:** `./scripts/setup.sh` runs every command in the two sections above. After that, run `./scripts/run-demo.sh` to repeat **all** demonstrations below. The demo script finds Pod names through the label `app=inventory` (none are hard-coded), checks every expected outcome, and exits non-zero if any check fails.

Real output of the deploy step (from [`evidence/setup-output.txt`](evidence/setup-output.txt)):

```
pod/client created
deployment.apps/inventory created
service/inventory-service created
Waiting for deployment "inventory" rollout to finish: 0 of 2 updated replicas are available...
Waiting for deployment "inventory" rollout to finish: 1 of 2 updated replicas are available...
deployment "inventory" successfully rolled out
pod/client condition met
```

---

## Verify Deployment

```
$ kubectl get deployments -o wide
NAME        READY   UP-TO-DATE   AVAILABLE   AGE   CONTAINERS   IMAGES          SELECTOR
inventory   2/2     2            2           4s    inventory    inventory:1.0   app=inventory

$ kubectl get pods -o wide
NAME                         READY   STATUS    RESTARTS   AGE   IP            NODE                          NOMINATED NODE   READINESS GATES
client                       1/1     Running   0          4s    10.244.0.18   inventory-lab-control-plane   <none>           <none>
inventory-768b4699c8-cz9lg   1/1     Running   0          4s    10.244.0.20   inventory-lab-control-plane   <none>           <none>
inventory-768b4699c8-k2qrz   1/1     Running   0          4s    10.244.0.19   inventory-lab-control-plane   <none>           <none>

$ kubectl get service inventory-service -o wide
NAME                TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)    AGE   SELECTOR
inventory-service   ClusterIP   10.96.37.255   <none>        8080/TCP   4s    app=inventory

$ kubectl get endpointslices -l kubernetes.io/service-name=inventory-service
NAME                      ADDRESSTYPE   PORTS   ENDPOINTS                 AGE
inventory-service-q5j6k   IPv4          8080    10.244.0.19,10.244.0.20   4s
```

* Deployment `inventory` shows **2/2** ready replicas.
* Both Inventory Pods are **`1/1 Running`**, and there is exactly **one** `client` Pod.
* Service `inventory-service` uses selector `app=inventory`, and its EndpointSlice lists **both** Pod IPs.

---

## Verify Kubernetes Service Discovery

The client is configured **only** with the Service DNS name ([`k8s/client.yaml`](k8s/client.yaml)):

```
$ kubectl get pod client -o jsonpath='{.spec.containers[0].env}'; echo
[{"name":"INVENTORY_URL","value":"http://inventory-service:8080/inventory"}]
```

Cluster DNS resolves the Service name to the Service's **ClusterIP** (`10.96.37.255`). It does not resolve to a Pod IP:

```
$ kubectl exec client -- nslookup inventory-service.default.svc.cluster.local
Server:		10.96.0.10
Address:	10.96.0.10:53

Name:	inventory-service.default.svc.cluster.local
Address: 10.96.37.255
```

A verbose request from the client using the short name `inventory-service`:

```
$ kubectl exec client -- curl -sv http://inventory-service:8080/inventory 2>&1 | grep -E 'Connected to|"pod"' | sed 's/, "items".*//'
* Connected to inventory-service (10.96.37.255) port 8080
{"service": "inventory", "pod": "inventory-768b4699c8-k2qrz", "pod_ip": "10.244.0.19", "node": "inventory-lab-control-plane", "message": "Inventory request handled successfully"

Service ClusterIP: 10.96.37.255
Inventory Pod IPs: 10.244.0.20 10.244.0.19
```

**Why this proves DNS-based discovery.** curl was given only the name `inventory-service` and connected to `10.96.37.255`, which is the Service ClusterIP. That address belongs to neither Inventory Pod (`10.244.0.19` and `10.244.0.20`). kube-proxy then forwarded the connection to a ready backend Pod. The client never knows or uses Pod IPs.

---

## Demonstrate Traffic Across Both Replicas

The command sends 20 requests, all to `http://inventory-service:8080/inventory`. Each `curl` runs as a separate process and opens a **new TCP connection**, so kube-proxy picks a backend independently for each request.

```
$ kubectl exec client -- sh -c 'for i in $(seq 1 20); do printf "request %02d -> " $i; curl -s http://inventory-service:8080/inventory | grep -o "\"pod\": \"[^\"]*\""; done'
request 01 -> "pod": "inventory-768b4699c8-cz9lg"
request 02 -> "pod": "inventory-768b4699c8-k2qrz"
request 03 -> "pod": "inventory-768b4699c8-k2qrz"
request 04 -> "pod": "inventory-768b4699c8-k2qrz"
request 05 -> "pod": "inventory-768b4699c8-cz9lg"
request 06 -> "pod": "inventory-768b4699c8-k2qrz"
request 07 -> "pod": "inventory-768b4699c8-k2qrz"
request 08 -> "pod": "inventory-768b4699c8-cz9lg"
request 09 -> "pod": "inventory-768b4699c8-cz9lg"
request 10 -> "pod": "inventory-768b4699c8-cz9lg"
request 11 -> "pod": "inventory-768b4699c8-k2qrz"
request 12 -> "pod": "inventory-768b4699c8-cz9lg"
request 13 -> "pod": "inventory-768b4699c8-cz9lg"
request 14 -> "pod": "inventory-768b4699c8-k2qrz"
request 15 -> "pod": "inventory-768b4699c8-k2qrz"
request 16 -> "pod": "inventory-768b4699c8-k2qrz"
request 17 -> "pod": "inventory-768b4699c8-k2qrz"
request 18 -> "pod": "inventory-768b4699c8-cz9lg"
request 19 -> "pod": "inventory-768b4699c8-k2qrz"
request 20 -> "pod": "inventory-768b4699c8-k2qrz"

Requests handled per Pod:
   8 inventory-768b4699c8-cz9lg
  12 inventory-768b4699c8-k2qrz
```

**Result.** All 20 requests went to one address, the Service, yet responses came from **two different Pods**: `inventory-768b4699c8-cz9lg` (8 requests) and `inventory-768b4699c8-k2qrz` (12 requests). The Service is load-balancing across both replicas.

> Kubernetes does **not** guarantee round-robin. kube-proxy (iptables mode here) picks a ready backend at random for each new connection, so the split is uneven (8/12) and varies between runs. The point is that repeated requests reach both replicas. A client that reuses one keep-alive connection would keep hitting the same Pod, which is why every request above opens a new connection.

---

## Readiness Probe Demonstration

The readiness probe from [`k8s/inventory-deployment.yaml`](k8s/inventory-deployment.yaml):

```yaml
readinessProbe:
  httpGet:
    path: /ready
    port: http          # 8080
  initialDelaySeconds: 2
  periodSeconds: 2      # probe every 2 s
  timeoutSeconds: 1
  successThreshold: 1
  failureThreshold: 1   # one failed probe marks the Pod NotReady
```

The short period and threshold make each transition take about 2 seconds, which keeps the demo quick and repeatable. The pod used below is **Pod A = `inventory-768b4699c8-cz9lg`**.

### Before Failure

```
$ kubectl get pods -l app=inventory -o wide
NAME                         READY   STATUS    RESTARTS   AGE   IP            NODE                          NOMINATED NODE   READINESS GATES
inventory-768b4699c8-cz9lg   1/1     Running   0          6s    10.244.0.20   inventory-lab-control-plane   <none>           <none>
inventory-768b4699c8-k2qrz   1/1     Running   0          6s    10.244.0.19   inventory-lab-control-plane   <none>           <none>

$ kubectl get endpointslices -l kubernetes.io/service-name=inventory-service -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}{"  ip="}{.addresses[0]}{"  ready="}{.conditions.ready}{"\n"}{end}'
inventory-768b4699c8-k2qrz  ip=10.244.0.19  ready=true
inventory-768b4699c8-cz9lg  ip=10.244.0.20  ready=true
```

Both Pods are `1/1 Running`, and both are ready endpoints of the Service.

### Trigger Failure

Readiness is failed on **only** Pod A, by running `curl` inside that Pod against its own `localhost` (the Inventory image includes `curl`). The Service is not involved, so the request is guaranteed to reach Pod A:

```
$ kubectl exec inventory-768b4699c8-cz9lg -- curl -s -X POST http://localhost:8080/readiness/fail
{"pod": "inventory-768b4699c8-cz9lg", "ready": false}

$ kubectl wait --for=condition=Ready=false pod/inventory-768b4699c8-cz9lg --timeout=30s
pod/inventory-768b4699c8-cz9lg condition met
```

### Verify Pod Is Running but Unready

```
$ kubectl get pods -l app=inventory -o wide
NAME                         READY   STATUS    RESTARTS   AGE   IP            NODE                          NOMINATED NODE   READINESS GATES
inventory-768b4699c8-cz9lg   0/1     Running   0          7s    10.244.0.20   inventory-lab-control-plane   <none>           <none>
inventory-768b4699c8-k2qrz   1/1     Running   0          7s    10.244.0.19   inventory-lab-control-plane   <none>           <none>

$ kubectl get pod inventory-768b4699c8-cz9lg -o jsonpath='phase={.status.phase}  ready={.status.containerStatuses[0].ready}  restarts={.status.containerStatuses[0].restartCount}'; echo
phase=Running  ready=false  restarts=0

$ kubectl exec inventory-768b4699c8-cz9lg -- curl -s -o /dev/null -w 'GET /health -> %{http_code}\n' http://localhost:8080/health
GET /health -> 200

$ kubectl exec inventory-768b4699c8-cz9lg -- curl -s -o /dev/null -w 'GET /ready  -> %{http_code}\n' http://localhost:8080/ready
GET /ready  -> 503

$ kubectl get events --field-selector involvedObject.name=inventory-768b4699c8-cz9lg,reason=Unhealthy -o custom-columns=TYPE:.type,REASON:.reason,MESSAGE:.message | head -3
TYPE      REASON      MESSAGE
Warning   Unhealthy   Readiness probe failed: HTTP probe failed with statuscode: 503
```

**Pod A is `0/1 Running` with 0 restarts.** The process is alive (`/health` returns 200, and `kubectl exec` works) but reports not-ready (`/ready` returns 503). The `Warning Unhealthy` line is the **expected** kubelet event recording the readiness probe failure. Pod B is still `1/1 Running`.

### Verify Service Traffic Avoids Unready Pod

```
$ kubectl get endpointslices -l kubernetes.io/service-name=inventory-service -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}{"  ip="}{.addresses[0]}{"  ready="}{.conditions.ready}{"\n"}{end}'
inventory-768b4699c8-k2qrz  ip=10.244.0.19  ready=true
inventory-768b4699c8-cz9lg  ip=10.244.0.20  ready=false
```

The Service's EndpointSlice now marks Pod A **`ready=false`**. kube-proxy routes Service traffic only to endpoints marked ready, which here means only Pod B (`10.244.0.19`).

Next, 20 normal requests through the Service while Pod A is unready:

```
$ kubectl exec client -- sh -c 'for i in $(seq 1 20); do printf "request %02d -> " $i; curl -s http://inventory-service:8080/inventory | grep -o "\"pod\": \"[^\"]*\""; done'
request 01 -> "pod": "inventory-768b4699c8-k2qrz"
request 02 -> "pod": "inventory-768b4699c8-k2qrz"
request 03 -> "pod": "inventory-768b4699c8-k2qrz"
request 04 -> "pod": "inventory-768b4699c8-k2qrz"
request 05 -> "pod": "inventory-768b4699c8-k2qrz"
request 06 -> "pod": "inventory-768b4699c8-k2qrz"
request 07 -> "pod": "inventory-768b4699c8-k2qrz"
request 08 -> "pod": "inventory-768b4699c8-k2qrz"
request 09 -> "pod": "inventory-768b4699c8-k2qrz"
request 10 -> "pod": "inventory-768b4699c8-k2qrz"
request 11 -> "pod": "inventory-768b4699c8-k2qrz"
request 12 -> "pod": "inventory-768b4699c8-k2qrz"
request 13 -> "pod": "inventory-768b4699c8-k2qrz"
request 14 -> "pod": "inventory-768b4699c8-k2qrz"
request 15 -> "pod": "inventory-768b4699c8-k2qrz"
request 16 -> "pod": "inventory-768b4699c8-k2qrz"
request 17 -> "pod": "inventory-768b4699c8-k2qrz"
request 18 -> "pod": "inventory-768b4699c8-k2qrz"
request 19 -> "pod": "inventory-768b4699c8-k2qrz"
request 20 -> "pod": "inventory-768b4699c8-k2qrz"

Requests handled per Pod:
  20 inventory-768b4699c8-k2qrz
```

**All 20 of 20 requests were served by Pod B (`k2qrz`). The unready Pod A (`cz9lg`) received none, even though it was still Running.** Every request succeeded, so the remaining ready Pod kept serving clients without interruption.

### Restore Readiness

```
$ kubectl exec inventory-768b4699c8-cz9lg -- curl -s -X POST http://localhost:8080/readiness/restore
{"pod": "inventory-768b4699c8-cz9lg", "ready": true}

$ kubectl wait --for=condition=Ready pod/inventory-768b4699c8-cz9lg --timeout=30s
pod/inventory-768b4699c8-cz9lg condition met

$ kubectl get pods -l app=inventory -o wide
NAME                         READY   STATUS    RESTARTS   AGE   IP            NODE                          NOMINATED NODE   READINESS GATES
inventory-768b4699c8-cz9lg   1/1     Running   0          11s   10.244.0.20   inventory-lab-control-plane   <none>           <none>
inventory-768b4699c8-k2qrz   1/1     Running   0          11s   10.244.0.19   inventory-lab-control-plane   <none>           <none>

$ kubectl get endpointslices -l kubernetes.io/service-name=inventory-service -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}{"  ip="}{.addresses[0]}{"  ready="}{.conditions.ready}{"\n"}{end}'
inventory-768b4699c8-k2qrz  ip=10.244.0.19  ready=true
inventory-768b4699c8-cz9lg  ip=10.244.0.20  ready=true
```

Pod A is back to **`1/1 Running`**, has the **same name and IP** as before (it was never restarted or replaced), and is again a `ready=true` endpoint of the Service.

### Verify Both Replicas Receive Traffic Again

```
$ kubectl exec client -- sh -c 'for i in $(seq 1 20); do printf "request %02d -> " $i; curl -s http://inventory-service:8080/inventory | grep -o "\"pod\": \"[^\"]*\""; done'
request 01 -> "pod": "inventory-768b4699c8-cz9lg"
request 02 -> "pod": "inventory-768b4699c8-cz9lg"
request 03 -> "pod": "inventory-768b4699c8-cz9lg"
request 04 -> "pod": "inventory-768b4699c8-k2qrz"
request 05 -> "pod": "inventory-768b4699c8-cz9lg"
request 06 -> "pod": "inventory-768b4699c8-k2qrz"
request 07 -> "pod": "inventory-768b4699c8-k2qrz"
request 08 -> "pod": "inventory-768b4699c8-cz9lg"
request 09 -> "pod": "inventory-768b4699c8-k2qrz"
request 10 -> "pod": "inventory-768b4699c8-cz9lg"
request 11 -> "pod": "inventory-768b4699c8-cz9lg"
request 12 -> "pod": "inventory-768b4699c8-cz9lg"
request 13 -> "pod": "inventory-768b4699c8-k2qrz"
request 14 -> "pod": "inventory-768b4699c8-k2qrz"
request 15 -> "pod": "inventory-768b4699c8-k2qrz"
request 16 -> "pod": "inventory-768b4699c8-cz9lg"
request 17 -> "pod": "inventory-768b4699c8-k2qrz"
request 18 -> "pod": "inventory-768b4699c8-k2qrz"
request 19 -> "pod": "inventory-768b4699c8-cz9lg"
request 20 -> "pod": "inventory-768b4699c8-k2qrz"

Requests handled per Pod:
  10 inventory-768b4699c8-cz9lg
  10 inventory-768b4699c8-k2qrz

$ kubectl get pods -l app=inventory -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount
NAME                         READY   RESTARTS
inventory-768b4699c8-cz9lg   true    0
inventory-768b4699c8-k2qrz   true    0

$ kubectl logs inventory-768b4699c8-cz9lg | grep -E 'listening|readiness'
2026-10-28T07:17:56Z pod=inventory-768b4699c8-cz9lg listening on :8080 (pod_ip=10.244.0.20, node=inventory-lab-control-plane)
2026-10-28T07:18:00Z pod=inventory-768b4699c8-cz9lg readiness set to FAILING (/ready now returns 503)
2026-10-28T07:18:03Z pod=inventory-768b4699c8-cz9lg readiness RESTORED (/ready now returns 200)
```

**The restored Pod A (`cz9lg`) is receiving Service traffic again** (10 of 20 requests). Its restart count is still **0**. The application log shows one process that started once, failed readiness, and recovered without ever being killed.

---

## Pod Failure and Recovery

### Pods Before Deletion

```
$ kubectl get pods -l app=inventory -o wide
NAME                         READY   STATUS    RESTARTS   AGE   IP            NODE                          NOMINATED NODE   READINESS GATES
inventory-768b4699c8-cz9lg   1/1     Running   0          12s   10.244.0.20   inventory-lab-control-plane   <none>           <none>
inventory-768b4699c8-k2qrz   1/1     Running   0          12s   10.244.0.19   inventory-lab-control-plane   <none>           <none>

$ kubectl get service inventory-service -o wide
NAME                TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)    AGE   SELECTOR
inventory-service   ClusterIP   10.96.37.255   <none>        8080/TCP   12s   app=inventory
Service identity before: name=inventory-service clusterIP=10.96.37.255 uid=4a2eb27e-f119-4e32-aaa6-d714778db254
Pod selected for deletion: inventory-768b4699c8-k2qrz (10.244.0.19)
```

### Delete One Pod

```
$ kubectl delete pod inventory-768b4699c8-k2qrz
pod "inventory-768b4699c8-k2qrz" deleted from default namespace

$ kubectl get pods -l app=inventory -o wide
NAME                         READY   STATUS              RESTARTS   AGE   IP            NODE                          NOMINATED NODE   READINESS GATES
inventory-768b4699c8-cz9lg   1/1     Running             0          13s   10.244.0.20   inventory-lab-control-plane   <none>           <none>
inventory-768b4699c8-qxvcs   0/1     ContainerCreating   0          0s    <none>        inventory-lab-control-plane   <none>           <none>
```

Right after the delete, `k2qrz` is gone and a **new** Pod `qxvcs`, 0 seconds old, is already in `ContainerCreating`. It gets no traffic until its readiness probe passes.

### Kubernetes Creates Replacement

```
$ kubectl rollout status deployment/inventory --timeout=120s
Waiting for deployment "inventory" rollout to finish: 1 of 2 updated replicas are available...
deployment "inventory" successfully rolled out

$ kubectl wait --for=condition=Ready pod -l app=inventory --timeout=120s
pod/inventory-768b4699c8-cz9lg condition met
pod/inventory-768b4699c8-qxvcs condition met

$ kubectl get pods -l app=inventory -o wide
NAME                         READY   STATUS    RESTARTS   AGE   IP            NODE                          NOMINATED NODE   READINESS GATES
inventory-768b4699c8-cz9lg   1/1     Running   0          16s   10.244.0.20   inventory-lab-control-plane   <none>           <none>
inventory-768b4699c8-qxvcs   1/1     Running   0          3s    10.244.0.21   inventory-lab-control-plane   <none>           <none>

$ kubectl get deployment inventory
NAME        READY   UP-TO-DATE   AVAILABLE   AGE
inventory   2/2     2            2           16s

$ kubectl get events --field-selector involvedObject.name=inventory-768b4699c8,reason=SuccessfulCreate --sort-by=.lastTimestamp -o custom-columns=REASON:.reason,OBJECT:.involvedObject.name,MESSAGE:.message | tail -1
SuccessfulCreate   inventory-768b4699c8   Created pod: inventory-768b4699c8-qxvcs
```

The ReplicaSet `inventory-768b4699c8`, owned by the Deployment, recorded **`Created pod: inventory-768b4699c8-qxvcs`**. Kubernetes did **not** bring back the deleted Pod. The ReplicaSet controller saw 1 actual Pod against the desired `replicas: 2`, and **reconciled** by creating a brand-new Pod from the Pod template. The Deployment is back to **2/2**.

### Compare Old and New Pod Identity

```
Pods before deletion : inventory-768b4699c8-cz9lg inventory-768b4699c8-k2qrz
Pods after deletion  : inventory-768b4699c8-cz9lg inventory-768b4699c8-qxvcs
Deleted Pod          : inventory-768b4699c8-k2qrz
Replacement Pod      : inventory-768b4699c8-qxvcs (10.244.0.21)

$ kubectl get pod inventory-768b4699c8-k2qrz 2>&1 || true
Error from server (NotFound): pods "inventory-768b4699c8-k2qrz" not found
```

| | Deleted Pod | Replacement Pod |
|---|---|---|
| Name | `inventory-768b4699c8-k2qrz` | `inventory-768b4699c8-qxvcs` |
| Pod IP | `10.244.0.19` | `10.244.0.21` |
| Exists now? | No (`NotFound`) | Yes, `1/1 Running` |

The replacement has a **different name and a different IP**. Any client that had hard-coded the old Pod's name or IP would now be broken.

### Verify Service Still Works

```
$ kubectl get service inventory-service -o wide
NAME                TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)    AGE   SELECTOR
inventory-service   ClusterIP   10.96.37.255   <none>        8080/TCP   17s   app=inventory
Service identity before: name=inventory-service clusterIP=10.96.37.255 uid=4a2eb27e-f119-4e32-aaa6-d714778db254
Service identity after : name=inventory-service clusterIP=10.96.37.255 uid=4a2eb27e-f119-4e32-aaa6-d714778db254

$ kubectl get endpointslices -l kubernetes.io/service-name=inventory-service -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}{"  ip="}{.addresses[0]}{"  ready="}{.conditions.ready}{"\n"}{end}'
inventory-768b4699c8-cz9lg  ip=10.244.0.20  ready=true
inventory-768b4699c8-qxvcs  ip=10.244.0.21  ready=true
```

The Service **name, ClusterIP (`10.96.37.255`) and UID are identical** before and after the deletion. Only its endpoints changed: the label selector `app=inventory` picked up the new Pod `qxvcs` automatically. The client configuration was **not changed**, and the same command against the same URL still works:

```
$ kubectl exec client -- sh -c 'for i in $(seq 1 20); do printf "request %02d -> " $i; curl -s http://inventory-service:8080/inventory | grep -o "\"pod\": \"[^\"]*\""; done'
request 01 -> "pod": "inventory-768b4699c8-qxvcs"
request 02 -> "pod": "inventory-768b4699c8-cz9lg"
request 03 -> "pod": "inventory-768b4699c8-qxvcs"
request 04 -> "pod": "inventory-768b4699c8-cz9lg"
request 05 -> "pod": "inventory-768b4699c8-cz9lg"
request 06 -> "pod": "inventory-768b4699c8-cz9lg"
request 07 -> "pod": "inventory-768b4699c8-cz9lg"
request 08 -> "pod": "inventory-768b4699c8-cz9lg"
request 09 -> "pod": "inventory-768b4699c8-qxvcs"
request 10 -> "pod": "inventory-768b4699c8-qxvcs"
request 11 -> "pod": "inventory-768b4699c8-qxvcs"
request 12 -> "pod": "inventory-768b4699c8-qxvcs"
request 13 -> "pod": "inventory-768b4699c8-qxvcs"
request 14 -> "pod": "inventory-768b4699c8-cz9lg"
request 15 -> "pod": "inventory-768b4699c8-cz9lg"
request 16 -> "pod": "inventory-768b4699c8-qxvcs"
request 17 -> "pod": "inventory-768b4699c8-qxvcs"
request 18 -> "pod": "inventory-768b4699c8-cz9lg"
request 19 -> "pod": "inventory-768b4699c8-qxvcs"
request 20 -> "pod": "inventory-768b4699c8-cz9lg"

Requests handled per Pod:
  10 inventory-768b4699c8-cz9lg
  10 inventory-768b4699c8-qxvcs
```

All 20 requests succeeded. The **replacement Pod `qxvcs` served 10 of them**, and the deleted Pod `k2qrz` served none.

The client's own background loop (one request per second to the same Service URL, set in `client.yaml`) ran the whole time. The log below covers the moment before the deletion through the period after the replacement was ready:

```
Pod deleted: inventory-768b4699c8-k2qrz at 07:18:07 (UTC)   Replacement: inventory-768b4699c8-qxvcs

$ kubectl logs client --since-time=2026-10-28T07:18:06Z
07:18:06 "pod": "inventory-768b4699c8-k2qrz"
07:18:07 "pod": "inventory-768b4699c8-cz9lg"
07:18:08 "pod": "inventory-768b4699c8-cz9lg"
07:18:09 "pod": "inventory-768b4699c8-cz9lg"
07:18:10 "pod": "inventory-768b4699c8-qxvcs"
07:18:11 "pod": "inventory-768b4699c8-cz9lg"
07:18:12 "pod": "inventory-768b4699c8-cz9lg"
07:18:13 "pod": "inventory-768b4699c8-qxvcs"
07:18:15 "pod": "inventory-768b4699c8-qxvcs"
07:18:16 "pod": "inventory-768b4699c8-qxvcs"
07:18:17 "pod": "inventory-768b4699c8-qxvcs"
```

| Time (UTC) | What the client saw through `inventory-service` |
|---|---|
| 07:18:06 | Served by **`k2qrz`**, the Pod that is about to be deleted |
| 07:18:07 | **`k2qrz` deleted.** Traffic continues on `cz9lg` |
| 07:18:10 onward | Served by the **replacement `qxvcs`** as well as `cz9lg` |

Every line is a successful response. A failed request would appear as `REQUEST FAILED`, and none did. The client used the same Service URL throughout.

**Takeaway.** Pods are ephemeral: their names and IPs change when they are replaced. The Service gives the client a **stable DNS name and ClusterIP**, and uses its **label selector** to route to whichever Pods currently match and are ready.

---

## Cleanup

```bash
# Delete the lab resources but keep the cluster
kubectl delete -f k8s/

# Delete the kind cluster too
kind delete cluster --name inventory-lab
```

Equivalent script: `./scripts/cleanup.sh` (resources only) or `./scripts/cleanup.sh --delete-cluster`.

---

## Reflection

**Why is a stable Service name useful when Pods can fail or be replaced?**

Pods are ephemeral: in this lab, deleting `inventory-768b4699c8-k2qrz` led Kubernetes to create `inventory-768b4699c8-qxvcs`, a Pod with a different name and IP, so any client that hard-coded a Pod address would have broken. A Service gives clients one stable DNS name and virtual IP (`inventory-service` → `10.96.37.255`) that do not change, while its label selector keeps the list of real backends up to date as Pods are created, deleted, or fail readiness checks. This lets the client stay decoupled from the backends: it does not need to find, track, or hard-code Pod identities, and it never has to change its configuration when a Pod is replaced. Together with readiness probes, the stable Service name lets the system stay resilient, because traffic moves to healthy replicas automatically while failed Pods recover or are replaced in the background.
