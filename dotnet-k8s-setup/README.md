# dotnet-k8s-setup

A simple **Todo** application built with:
- **.NET 10 Minimal API**
- **Entity Framework Core + PostgreSQL (Npgsql)**
- **Vertical Slice Architecture** (`Features/Todos/`)
- **Kubernetes** with dynamic config via ConfigMap & Secrets

---

## Table of Contents

1. [Project Structure](#project-structure)
2. [How Configuration Works](#how-configuration-works)
3. [Local Development](#local-development)
4. [Kubernetes Setup — Step by Step](#kubernetes-setup--step-by-step)
   - [Step 1 — Install nginx Ingress Controller](#step-1--install-nginx-ingress-controller)
   - [Step 2 — Build the Docker Image](#step-2--build-the-docker-image)
   - [Step 3 — Deploy All Manifests](#step-3--deploy-all-manifests)
   - [Step 4 — Add hosts entry](#step-4--add-hosts-entry)
5. [How Ingress Works — Inside vs Outside the Cluster](#how-ingress-works--inside-vs-outside-the-cluster)
6. [Production Ingress Best Practices](#production-ingress-best-practices)
   - [Option 0 — Docker Desktop / minikube (this repo)](#option-0--docker-desktop--minikube-this-repo--local-dev-only)
   - [Option 1 — Cloud Provider LoadBalancer](#option-1--cloud-provider-loadbalancer-managed-clusters)
   - [Option 2 — NodePort](#option-2--nodeport-simplest-bare-metal--any-cluster)
   - [Option 3 — MetalLB (recommended for bare-metal)](#option-3--metallb-recommended-for-bare-metal)
   - [Option 4 — HostNetwork / HostPort](#option-4--hostnetwork--hostport-daemonset-mode)
   - [Decision guide](#decision-guide--which-option-to-choose)
   - [TLS termination](#tls-termination-all-environments)
   - [Should you expose the Ingress Controller directly?](#should-you-expose-the-ingress-controller-directly-to-the-internet)
   - [The two-layer production architecture](#the-two-layer-production-architecture)
   - [Edge layer options](#edge-layer-options-by-cloud-and-approach)
   - [Summary: direct vs layered](#summary-direct-vs-layered-exposure)
7. [Kubernetes Command Reference](#kubernetes-command-reference)
8. [API Endpoints](#api-endpoints)
9. [Testing with the HTTP Client](#testing-with-the-http-client)

---

## Project Structure

```
dotnet-k8s-setup/
├── Dockerfile
├── .dockerignore
│
├── DotnetK8sSetup/
│   ├── Features/
│   │   └── Todos/
│   │       ├── TodoItem.cs           ← Entity
│   │       ├── TodoDbContext.cs      ← DbContext (scoped to this slice)
│   │       ├── TodoEndpoints.cs      ← All 5 CRUD routes (MapGroup extension)
│   │       ├── TodoModels.cs         ← Request / response records
│   │       └── Migrations/           ← EF Core migrations (auto-applied on startup)
│   ├── appsettings.json              ← Local dev defaults (overridden in K8s)
│   ├── Program.cs
│   ├── todos.http                    ← HTTP client test file (Rider / VS)
│   └── http-client.env.json          ← local + k8s environment variables
│
└── k8s/
    ├── namespace.yaml                ← dotnet-k8s namespace
    ├── configmap.yaml                ← Non-sensitive settings → mounted as appsettings.json
    ├── secret.yaml                   ← Connection string + DB password
    ├── postgres.yaml                 ← In-cluster PostgreSQL (dev/demo only)
    ├── deployment.yaml               ← 3 replicas, volume mount + env var injection
    ├── service.yaml                  ← ClusterIP (internal only, Ingress is the entry point)
    └── ingress.yaml                  ← nginx Ingress → routes todo-app.local → service
```

---

## How Configuration Works

.NET's default host builder loads configuration in this priority order (later wins):

| Priority | Source | Provided by |
|---|---|---|
| 1 | `appsettings.json` | **ConfigMap** volume-mounted at `/app/appsettings.json` |
| 2 | `appsettings.{Environment}.json` | Not present in Production — skipped |
| 3 | Environment variables | **Secret** key injected as env var — wins over the file |

### ConfigMap → `appsettings.json`

`configmap.yaml` holds non-sensitive settings (log levels, `AllowedHosts`, feature flags).
The Deployment mounts it directly over `/app/appsettings.json` using `subPath`:

```yaml
volumeMounts:
  - name: config-volume
    mountPath: /app/appsettings.json
    subPath: appsettings.json   # overlays only this file, /app stays intact
    readOnly: true
```

The published .NET app's working directory is `/app`, so the file is picked up by the default
`WebApplication.CreateBuilder` pipeline — **no `AddJsonFile` or any code change needed**.

### Secret → Environment Variable

`secret.yaml` stores the connection string under `ConnectionStrings__DefaultConnection`.
The Deployment injects it as an environment variable:

```yaml
env:
  - name: ConnectionStrings__DefaultConnection
    valueFrom:
      secretKeyRef:
        name: todo-app-secret
        key: ConnectionStrings__DefaultConnection
```

.NET Configuration maps the double-underscore (`__`) separator to the colon (`:`) hierarchy,
so `IConfiguration["ConnectionStrings:DefaultConnection"]` resolves to the secret value
automatically, overriding any value from `appsettings.json` — **no code changes required**.

---

## Local Development

```bash
# 1. Start a local PostgreSQL container
docker run -d --name pg \
  -e POSTGRES_DB=todos \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=postgres \
  -p 5432:5432 \
  postgres:16-alpine

# 2. Run the app (EF migrations are applied automatically on startup)
cd DotnetK8sSetup
dotnet run

# API:     http://localhost:5239/todos
# OpenAPI: http://localhost:5239/openapi/v1.json
```

---

## Kubernetes Setup — Step by Step

### Step 1 — Install nginx Ingress Controller

The nginx Ingress Controller is a pod that runs **inside** the cluster and handles all inbound
HTTP traffic. On Docker Desktop it is exposed to your host via a `LoadBalancer` service that
Docker Desktop maps to `localhost`.

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.0/deploy/static/provider/cloud/deploy.yaml

# Wait for the controller pod to be ready
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s

# Verify: should show Type=LoadBalancer, EXTERNAL-IP=localhost (Docker Desktop)
kubectl get svc ingress-nginx-controller -n ingress-nginx
```

### Step 2 — Build the Docker Image

```bash
# From the repo root (where Dockerfile lives)
docker build -t dotnet-k8s-setup:latest .

# For a real registry (e.g., GHCR, Docker Hub, ACR) — replace <registry>
docker build -t <registry>/dotnet-k8s-setup:latest .
docker push <registry>/dotnet-k8s-setup:latest
# Then update image: in k8s/deployment.yaml to match
```

### Step 3 — Deploy All Manifests

Apply in this order (namespace and secrets must exist before pods start):

```bash
kubectl apply -f k8s/namespace.yaml    # 1. create the dotnet-k8s namespace first
kubectl apply -f k8s/secret.yaml       # 2. secrets before pods reference them
kubectl apply -f k8s/configmap.yaml    # 3. configmap before pods reference it
kubectl apply -f k8s/postgres.yaml     # 4. database (PVC + Deployment + Service)
kubectl apply -f k8s/deployment.yaml   # 5. app (3 replicas)
kubectl apply -f k8s/service.yaml      # 6. ClusterIP service
kubectl apply -f k8s/ingress.yaml      # 7. Ingress rule

# Or apply the whole folder at once (order is handled by K8s dependency resolution):
kubectl apply -f k8s/

# Watch the rollout
kubectl rollout status deployment/todo-app -n dotnet-k8s --timeout=120s
```

### Step 4 — Add hosts entry

The Ingress rule routes traffic for `todo-app.local`. Add it to your hosts file so your OS
resolves the name to `localhost` (where Docker Desktop exposes the LoadBalancer):

**Windows (run as Administrator):**
```powershell
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "127.0.0.1 todo-app.local"
```

**macOS / Linux:**
```bash
echo "127.0.0.1 todo-app.local" | sudo tee -a /etc/hosts
```

After this, `http://todo-app.local/todos` works directly in your browser and HTTP client.

---

## How Ingress Works — Inside vs Outside the Cluster

This is a common point of confusion. Here is the exact traffic flow for this setup:

```
Your browser / HTTP client (host machine)
        │
        │  http://todo-app.local  →  resolves to 127.0.0.1 via /etc/hosts
        │
        ▼
┌─────────────────────────────────────────────────────────┐
│  Docker Desktop port-forward (host port 80)             │  ← HOST MACHINE boundary
│  Maps localhost:80 → ingress-nginx-controller pod:80    │
└─────────────────────────────────────────────────────────┘
        │
        ▼  (now INSIDE the cluster)
┌─────────────────────────────────────────────────────────┐
│  ingress-nginx-controller  (type: LoadBalancer)         │
│  Reads the Ingress rule: host=todo-app.local → /        │
│  Forwards to: todo-app-service:80                       │
│                                                         │
│  todo-app-service  (type: ClusterIP — internal only)    │
│  Load-balances across the 3 todo-app pods               │
│                                                         │
│  todo-app pod 1 :8080  ┐                                │
│  todo-app pod 2 :8080  ├─ one of these handles request  │
│  todo-app pod 3 :8080  ┘                                │
└─────────────────────────────────────────────────────────┘
```

### Key points

| Question | Answer |
|---|---|
| Is the **Ingress object** inside the cluster? | Yes — `Ingress` is a K8s resource that lives inside the cluster |
| Is the **nginx Ingress Controller** inside the cluster? | Yes — it runs as a pod inside the cluster |
| Is it accessible **from outside** the cluster? | **Yes, on Docker Desktop** — Docker Desktop intercepts `type: LoadBalancer` and port-forwards it to `localhost` on your host machine. See [Option 0](#option-0--docker-desktop--minikube-this-repo--local-dev-only) for a full explanation. |
| Why does `todo-app-service` use `ClusterIP` and not `LoadBalancer`? | `ClusterIP` is intentional — the app Service is **internal only**. Only the Ingress controller needs to be exposed. All external traffic enters through the Ingress controller, which then forwards to the ClusterIP service. |
| What happens on bare-metal if you use `type: LoadBalancer`? | The Service stays stuck at `EXTERNAL-IP: <pending>` forever — there is no cloud API to call. See [Production Ingress Best Practices](#production-ingress-best-practices) for solutions. |

---

## Production Ingress Best Practices

### The core problem: who exposes the Ingress Controller?

The Ingress Controller is just a pod. Something must route external traffic **into** it.
On managed cloud providers that "something" is a cloud load balancer, provisioned automatically
when you set `type: LoadBalancer`. On **bare-metal** there is no cloud API to call, so
`type: LoadBalancer` Services stay stuck in `<pending>` forever.

```
Cloud provider:        Internet → Cloud LB (public IP) → Ingress Controller pod
Bare-metal (problem):  Internet → ??? (LoadBalancer = <pending>) → Ingress Controller pod
```

The solutions below address this gap, **starting with the local dev setup used in this repo**.

---

### Option 0 — Docker Desktop / minikube (this repo — local dev only)

**Use when:** developing on your laptop with Docker Desktop or minikube. **Not for production.**

This is the approach used in this repository. The ingress-nginx-controller Service is type
`LoadBalancer`, but there is no real cloud load balancer involved. Instead, both Docker Desktop
and minikube ship with a built-in mechanism that intercepts `LoadBalancer` Services and maps
them to your host machine:

#### How Docker Desktop does it

Docker Desktop runs a single-node Kubernetes cluster **inside a lightweight VM** (HyperV on
Windows, HyperKit on macOS). It ships with its own `LoadBalancer` controller that watches for
`type: LoadBalancer` Services and automatically configures a **port-forward from the VM into
`localhost` on your host machine**.

```
Host machine  (Windows / macOS)
   │
   │  http://todo-app.local:80
   │  resolves to 127.0.0.1 via /etc/hosts
   │
   ▼
localhost:80  ◄── Docker Desktop port-forward ──►  VM:80
                                                        │
                                          ┌─────────────┘  (inside the VM = inside the cluster)
                                          ▼
                              ingress-nginx-controller Service
                              EXTERNAL-IP: localhost   ← Docker Desktop sets this
                              type: LoadBalancer
                                          │
                                          ▼
                              ingress-nginx-controller Pod
                                          │  reads Ingress rules
                                          ▼
                              todo-app-service (ClusterIP)
                                          │
                                          ▼
                              todo-app pods (×3)
```

You can verify this yourself — this is the exact output from our cluster:
```bash
kubectl get svc ingress-nginx-controller -n ingress-nginx
# NAME                       TYPE           CLUSTER-IP       EXTERNAL-IP   PORT(S)
# ingress-nginx-controller   LoadBalancer   10.106.75.174    localhost     80:30525/TCP,443:30315/TCP
#                                                            ^^^^^^^^^
#                                           Docker Desktop sets EXTERNAL-IP = localhost automatically
```

`EXTERNAL-IP: localhost` is the key. On a real cluster or bare-metal, this field would either
show a public IP (cloud) or stay `<pending>` forever (bare-metal with no LB provider).

#### How minikube does it (different mechanism, same result)

minikube does **not** auto-map `LoadBalancer` Services. Instead you run `minikube tunnel` in a
separate terminal, which creates a network route from your host to the minikube VM and assigns
each `LoadBalancer` Service an IP from the VM's subnet:

```bash
minikube tunnel   # run in a separate terminal, requires sudo/admin
# Now LoadBalancer Services get a real IP (e.g. 192.168.49.2)
kubectl get svc ingress-nginx-controller -n ingress-nginx
# EXTERNAL-IP: 192.168.49.2
```

#### Why this only works locally

| Detail | Docker Desktop | minikube tunnel | Real cloud |
|---|---|---|---|
| Mechanism | Built-in port-forward from VM to host `localhost` | Network route from host to VM subnet | Cloud provider creates a real external IP |
| `EXTERNAL-IP` value | `localhost` | VM subnet IP (e.g. `192.168.49.2`) | Real public IP / DNS |
| Accessible from other machines on your network? | ❌ No — `localhost` only | ❌ No — VM subnet IP, not routable externally | ✅ Yes |
| Production suitable? | ❌ No | ❌ No | ✅ Yes |

This is why you need one of Options 1–4 for anything beyond your own laptop.

---

### Option 1 — Cloud Provider LoadBalancer (managed clusters)

**Use when:** AWS EKS, Azure AKS, Google GKE, DigitalOcean, etc.

The cloud control-plane watches for `type: LoadBalancer` Services and automatically provisions
a cloud load balancer (ALB, NLB, Azure LB, etc.) with a public IP or DNS name.

```
Internet
   │
   ▼
Cloud Load Balancer  (public IP — provisioned by cloud)
   │  TCP passthrough on port 80/443
   ▼
ingress-nginx-controller Service  (type: LoadBalancer)
   │
   ▼
ingress-nginx-controller Pod  (reads Ingress rules)
   │
   ▼
todo-app-service  (ClusterIP — internal)
   │
   ▼
todo-app pods
```

**Production additions on top of this:**
- Attach a **TLS certificate** (cert-manager + Let's Encrypt) to the Ingress controller so
  traffic is encrypted end-to-end.
- On AWS, annotate the Service to use an **NLB** (better for Kubernetes):
  ```yaml
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
  ```
- On Azure AKS, consider using the **Application Gateway Ingress Controller (AGIC)** which
  runs the load balancer as an Azure-native service outside the cluster entirely.

---

### Option 2 — NodePort (simplest bare-metal / any cluster)

**Use when:** bare-metal, on-prem, small clusters, or when you already have an external
load balancer / reverse proxy (HAProxy, F5, hardware LB) in front of your nodes.

`NodePort` opens a port (default range `30000–32767`) on **every node's IP**. Your external
load balancer or DNS round-robins across those node IPs.

```
Internet
   │
   ▼
External LB / HAProxy / DNS round-robin  (your own hardware or VM)
   │  forwards to  <any-node-IP>:30080  and  <any-node-IP>:30443
   ▼
Kubernetes Node (any node)
   │  NodePort routes internally
   ▼
ingress-nginx-controller Pod
   │
   ▼
todo-app-service (ClusterIP) → todo-app pods
```

Change the ingress controller Service to `NodePort`:

```yaml
# k8s/ingress-nginx-nodeport-patch.yaml
apiVersion: v1
kind: Service
metadata:
  name: ingress-nginx-controller
  namespace: ingress-nginx
spec:
  type: NodePort
  ports:
    - name: http
      port: 80
      targetPort: http
      nodePort: 30080      # fixed port, easier to configure firewall rules
    - name: https
      port: 443
      targetPort: https
      nodePort: 30443
```

Apply after installing the controller:
```bash
kubectl patch svc ingress-nginx-controller -n ingress-nginx \
  --patch-file k8s/ingress-nginx-nodeport-patch.yaml
```

**Drawbacks:** NodePort range is non-standard (not port 80/443 directly), so you need
something in front to translate — which is what MetalLB (Option 3) solves.

---

### Option 3 — MetalLB (recommended for bare-metal)

**Use when:** bare-metal, on-prem, homelab, any cluster where you want real `LoadBalancer`
behaviour without a cloud provider. MetalLB is a Kubernetes-native load balancer that runs
**inside** the cluster and handles IP allocation from a pool you define.

MetalLB has two modes:

| Mode | How it works | When to use |
|---|---|---|
| **Layer 2 (ARP)** | One node "owns" the IP and announces it via ARP. Failover is automatic. | Single subnet, homelab, simple on-prem |
| **BGP** | All nodes advertise routes via BGP to your router/switch. True ECMP load balancing. | Data centre, multi-rack, enterprise on-prem |

```
Internet / LAN
   │
   ▼
MetalLB IP pool  e.g. 192.168.1.200–192.168.1.210
   │  MetalLB announces 192.168.1.200 via ARP (L2) or BGP
   │  Traffic arrives at the elected node
   ▼
ingress-nginx-controller Service  (type: LoadBalancer ← MetalLB fulfils this)
   │
   ▼
ingress-nginx-controller Pod
   │
   ▼
todo-app-service (ClusterIP) → todo-app pods
```

**Install MetalLB:**
```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml

# Wait for MetalLB pods
kubectl wait --namespace metallb-system \
  --for=condition=ready pod \
  --selector=app=metallb \
  --timeout=90s
```

**Configure an IP pool (Layer 2 example):**
```yaml
# k8s/metallb-config.yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
    - 192.168.1.200-192.168.1.210   # ← IPs from your LAN that are free
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: metallb-system
spec:
  ipAddressPools:
    - default-pool
```

```bash
kubectl apply -f k8s/metallb-config.yaml

# The ingress-nginx-controller Service now gets a real IP from the pool
kubectl get svc ingress-nginx-controller -n ingress-nginx
# NAME                       TYPE           EXTERNAL-IP      PORT(S)
# ingress-nginx-controller   LoadBalancer   192.168.1.200    80:30525/TCP,443:30315/TCP
```

No code or manifest changes are needed to the Ingress or app — MetalLB fulfils the
`LoadBalancer` contract transparently.

---

### Option 4 — HostNetwork / HostPort (DaemonSet mode)

**Use when:** edge nodes, single-node clusters, or you want the controller to bind
**directly to the host's network interfaces** at port 80/443 with no intermediate Service.

```
Internet
   │  port 80/443 on the physical node IP
   ▼
Node network interface  (hostNetwork: true)
   │  directly received by the ingress-nginx pod
   ▼
ingress-nginx-controller Pod  (running as DaemonSet on every node)
   │
   ▼
todo-app-service (ClusterIP) → todo-app pods
```

The controller is deployed as a **DaemonSet** (one pod per node) with `hostNetwork: true`:

```yaml
# excerpt — ingress-nginx DaemonSet spec
spec:
  hostNetwork: true
  dnsPolicy: ClusterFirstWithHostNet
  containers:
    - name: controller
      ports:
        - containerPort: 80
          hostPort: 80       # binds to node port 80 directly
        - containerPort: 443
          hostPort: 443
```

**Drawbacks:** the pod consumes port 80/443 on the node — nothing else can use those ports.
Not suitable for shared nodes.

---

### Decision guide — which option to choose?

```
Are you developing locally on your laptop?
  ├─ Docker Desktop → type: LoadBalancer  (Option 0) ✅  auto-maps to localhost, zero config
  └─ minikube       → minikube tunnel     (Option 0) ✅  run tunnel, LB gets a VM subnet IP

Are you on a managed cloud (EKS / AKS / GKE / DO)?
  └─ YES → Use type: LoadBalancer  (Option 1) ✅  simple, automatic, production-ready

Are you on bare-metal / on-prem?
  │
  ├─ Do you already have a hardware LB or HAProxy in front of your nodes?
  │    └─ YES → Use NodePort  (Option 2) ✅  let your existing LB forward to node:30080
  │
  ├─ Do you want native LoadBalancer behaviour without external hardware?
  │    └─ YES → Use MetalLB  (Option 3) ✅  recommended for most bare-metal setups
  │
  └─ Edge / single-node / IoT / need zero extra components?
       └─ YES → Use HostNetwork DaemonSet  (Option 4) ✅  lowest overhead, simplest
```

---

### TLS termination (all environments)

Regardless of which option you use, **always terminate TLS at the Ingress Controller**
in production. The standard approach is:

1. Install [cert-manager](https://cert-manager.io):
   ```bash
   kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.0/cert-manager.yaml
   ```

2. Create a `ClusterIssuer` for Let's Encrypt:
   ```yaml
   apiVersion: cert-manager.io/v1
   kind: ClusterIssuer
   metadata:
     name: letsencrypt-prod
   spec:
     acme:
       server: https://acme-v02.api.letsencrypt.org/directory
       email: your@email.com
       privateKeySecretRef:
         name: letsencrypt-prod
       solvers:
         - http01:
             ingress:
               ingressClassName: nginx
   ```

3. Annotate the Ingress to auto-provision a certificate:
   ```yaml
   # k8s/ingress.yaml  (production version)
   apiVersion: networking.k8s.io/v1
   kind: Ingress
   metadata:
     name: todo-app-ingress
     namespace: dotnet-k8s
     annotations:
       cert-manager.io/cluster-issuer: "letsencrypt-prod"
       nginx.ingress.kubernetes.io/ssl-redirect: "true"
   spec:
     ingressClassName: nginx
     tls:
       - hosts:
           - todo-app.yourdomain.com
         secretName: todo-app-tls       # cert-manager fills this Secret automatically
     rules:
       - host: todo-app.yourdomain.com
         http:
           paths:
             - path: /
               pathType: Prefix
               backend:
                 service:
                   name: todo-app-service
                   port:
                     number: 80
   ```

cert-manager handles certificate renewal automatically. Your app Service stays `ClusterIP`
and knows nothing about TLS — it remains HTTP internally.

---

### Should you expose the Ingress Controller directly to the internet?

**Short answer: No — not in production.**

Exposing the nginx Ingress Controller directly via a cloud `LoadBalancer` with a public IP
works fine for simple setups, but it means **raw internet traffic hits your cluster boundary
first**. There is no layer in between to absorb DDoS attacks, block malicious requests, or
cache static content before they consume cluster resources.

The cloud-native production best practice is to put a **dedicated edge layer** in front of
the Ingress Controller. The Ingress Controller then becomes an **internal component**
reachable only from that edge layer, not from the open internet.

```
❌  Simple (avoid in production):

    Internet ──────────────────────────────────► nginx Ingress Controller (public IP)
                                                         │
                                                    app pods

────────────────────────────────────────────────────────────────────────────────────────

✅  Production best practice:

    Internet ──► Edge Layer (WAF + DDoS + CDN + TLS) ──► nginx Ingress Controller
                 • Blocks OWASP Top 10 attacks                (internal / private IP only)
                 • Absorbs DDoS before cluster sees it                │
                 • Terminates TLS, offloads certs                app pods
                 • Caches static assets at the edge
                 • Global anycast / geo-routing
```

#### Why the Ingress Controller alone is not enough

| Concern | nginx Ingress Controller | Dedicated Edge Layer |
|---|---|---|
| **WAF / OWASP rules** | Basic (modsecurity plugin, manual config) | Built-in, managed, auto-updated |
| **DDoS protection** | ❌ None — cluster absorbs all traffic | ✅ Absorbed at edge before cluster |
| **TLS certificate management** | cert-manager (you manage) | Managed by cloud provider |
| **Global CDN / caching** | ❌ None | ✅ Static assets cached globally |
| **Geo-routing / failover** | ❌ Single region | ✅ Route to nearest healthy region |
| **Rate limiting** | Annotation-based, per-ingress | Global, policy-driven |
| **Bot protection** | ❌ None | ✅ Managed bot rules |
| **IP allowlisting** | Manual annotation | Centralised policy |

---

### The two-layer production architecture

The key insight is: **the Ingress Controller service should be `internal` (private IP), not
public**. The edge layer gets the public IP. The Ingress Controller is only reachable from
within the cloud VNet/VPC.

```
Internet
   │
   ▼
┌──────────────────────────────────────────────────────┐
│  EDGE LAYER  (outside the cluster — managed service) │
│                                                      │
│  • Public IP / Anycast DNS                           │
│  • TLS termination                                   │
│  • WAF (OWASP CRS, custom rules)                     │
│  • DDoS protection                                   │
│  • CDN / response caching                            │
│  • Rate limiting, bot protection                     │
│  • Geo-blocking / IP allowlisting                    │
└──────────────────────────────────────────────────────┘
   │  HTTPS (or HTTP inside private VNet)
   │  traffic forwarded to INTERNAL load balancer IP
   ▼
┌──────────────────────────────────────────────────────┐
│  KUBERNETES CLUSTER  (private VNet/VPC)              │
│                                                      │
│  nginx Ingress Controller                            │
│  Service type: LoadBalancer, INTERNAL annotation     │
│  No public IP — only a private VNet IP               │
│                 │                                    │
│                 ▼                                    │
│  todo-app-service (ClusterIP)                        │
│                 │                                    │
│                 ▼                                    │
│  todo-app pods (×3)                                  │
└──────────────────────────────────────────────────────┘
```

Making the Ingress Controller internal-only (no public IP) is done with a single annotation
on the controller Service, which varies by cloud:

```yaml
# Azure AKS — internal load balancer
service.beta.kubernetes.io/azure-load-balancer-internal: "true"

# AWS EKS — internal NLB
service.beta.kubernetes.io/aws-load-balancer-internal: "true"
service.beta.kubernetes.io/aws-load-balancer-type: "nlb"

# Google GKE — internal load balancer
networking.gke.io/load-balancer-type: "Internal"
```

---

### Edge layer options by cloud and approach

#### Option A — Cloud CDN + WAF in front of nginx (most common)

Use your cloud's native WAF/CDN product as the edge. The nginx Ingress Controller stays
internal and handles K8s-specific routing (path-based, header-based, canary, etc.).
The WAF handles security and the CDN handles performance.

| Cloud | Edge product | Notes |
|---|---|---|
| **Azure** | Azure Front Door + WAF Policy | Global CDN + WAF + DDoS in one; routes to internal AKS LB |
| **Azure** | Application Gateway WAF v2 | Regional L7 LB + WAF; AGIC can replace nginx entirely |
| **AWS** | CloudFront + AWS WAF + Shield | CDN + WAF + DDoS; routes to internal NLB |
| **AWS** | AWS ALB (via AWS Load Balancer Controller) | Can replace nginx entirely for AWS-native routing |
| **GCP** | Cloud Armor + Cloud Load Balancing | WAF + DDoS + global LB; routes to internal GKE LB |
| **Any cloud** | Cloudflare (DNS proxy mode) | CDN + WAF + DDoS + bot protection; cloud-agnostic |

```
Azure example:

Internet ──► Azure Front Door (WAF Policy + CDN + DDoS)
                  │  private peering or public HTTPS to origin
                  ▼
             nginx Ingress Controller
             (internal Azure LB — no public IP)
                  │
                  ▼
             todo-app pods
```

```
AWS example:

Internet ──► CloudFront + AWS WAF + Shield Standard
                  │  HTTPS to origin (internal NLB DNS)
                  ▼
             nginx Ingress Controller
             (internal NLB — no public IP)
                  │
                  ▼
             todo-app pods
```

#### Option B — Replace nginx with a cloud-native ingress controller

Some cloud-native ingress controllers are themselves the WAF + LB combined, eliminating the
need for a separate edge layer while still running outside the cluster:

| Controller | Cloud | What it is |
|---|---|---|
| **AGIC** (Application Gateway Ingress Controller) | Azure | Azure Application Gateway WAF v2 is the LB. An AGIC pod inside the cluster watches Ingress resources and configures the gateway via ARM. No nginx inside cluster at all. |
| **AWS Load Balancer Controller** | AWS | Creates AWS ALB/NLB directly from Ingress/Service resources. WAF can be attached to the ALB. |
| **GKE Gateway API** | GCP | Provisions Google Cloud Load Balancer with Cloud Armor (WAF) from Gateway resources. |

**AGIC architecture (Azure):**

```
Internet
   │
   ▼
Azure Application Gateway WAF v2  (outside the cluster — Azure-managed)
   │  • WAF rules (OWASP CRS)
   │  • TLS termination
   │  • Autoscaling
   │  • Talks to pods via private IP directly (no NodePort/kube-proxy hop)
   ▼
AKS pod IPs  (directly — bypasses ClusterIP and kube-proxy entirely)
```

> The AGIC pod inside the cluster only reads Ingress objects and pushes config to the
> Application Gateway via the Azure API. It does **not** sit in the data path.

#### Option C — Cloudflare (cloud-agnostic, any cluster)

Cloudflare's DNS proxy mode is cloud-agnostic and works in front of any Kubernetes cluster
regardless of provider. It is a popular choice for self-hosted, multi-cloud, or bare-metal.

```
Internet
   │
   ▼
Cloudflare edge  (global anycast, 300+ PoPs)
   │  • WAF (OWASP + managed rules + custom rules)
   │  • DDoS protection (free tier covers most attacks)
   │  • CDN / caching
   │  • Bot management
   │  • TLS termination (Cloudflare manages certs)
   │  • Rate limiting
   │
   │  HTTPS origin pull  →  your cluster's public IP
   ▼
nginx Ingress Controller  (can be public IP here — Cloudflare masks it)
   │  or use Cloudflare Tunnel (cloudflared) — no public IP at all
   ▼
todo-app pods
```

**Cloudflare Tunnel** (`cloudflared`) is the most secure option — the cluster makes an
**outbound** tunnel to Cloudflare's edge. Your cluster has **no inbound public port at all**:

```
Cluster (no public IP needed)
   │  cloudflared pod makes outbound HTTPS connection to Cloudflare
   ▼
Cloudflare edge  ◄──── Internet traffic arrives here
```

This is especially useful for bare-metal or home-lab clusters that are behind NAT.

---

### Summary: direct vs layered exposure

| Approach | Public IP on Ingress? | WAF | DDoS | CDN | Use case |
|---|---|---|---|---|---|
| Direct (nginx + public LB) | ✅ Yes | ❌ None | ❌ None | ❌ None | Dev/staging only |
| nginx (internal) + Cloud WAF/CDN | ❌ No | ✅ | ✅ | ✅ | ✅ Production (cloud) |
| AGIC / AWS ALB Controller | ❌ No nginx at all | ✅ | ✅ | Partial | ✅ Production (cloud-native) |
| nginx + Cloudflare proxy | ❌ (Cloudflare masks it) | ✅ | ✅ | ✅ | ✅ Production (any cluster) |
| nginx + Cloudflare Tunnel | ❌ No public IP at all | ✅ | ✅ | ✅ | ✅ Production (bare-metal / NAT) |

> **Rule of thumb:** the Ingress Controller is an internal traffic router — it should live
> on a private IP inside your VNet. The internet-facing endpoint should always be a managed
> edge service (WAF + CDN + DDoS) that you or your cloud provider operate separately from
> the cluster.

---

### Environments comparison

| Environment | Option | Mechanism | `EXTERNAL-IP` | External access |
|---|---|---|---|---|
| **Docker Desktop** (this repo) | 0 | Built-in VM→host port-forward | `localhost` | localhost only ❌ |
| **minikube** | 0 | `minikube tunnel` network route | VM subnet IP | localhost only ❌ |
| **AWS EKS** | 1 | Cloud provisions NLB/ALB | Public DNS | ✅ Internet |
| **Azure AKS** | 1 | Cloud provisions Azure LB (or AGIC) | Public IP | ✅ Internet |
| **Google GKE** | 1 | Cloud provisions GCP LB | Public IP | ✅ Internet |
| **Bare-metal + existing LB** | 2 | NodePort → your HAProxy/F5 forwards | Node IP + port | ✅ LAN / Internet |
| **Bare-metal (no existing LB)** | 3 | MetalLB ARP/BGP IP announcement | LAN IP from pool | ✅ LAN / Internet |
| **Edge / single-node** | 4 | HostNetwork binds pod to node NIC | Node IP directly | ✅ LAN / Internet |

---

## Kubernetes Command Reference

### Cluster overview

```bash
# All resources in the app namespace
kubectl get all -n dotnet-k8s

# Pods with node placement and IP
kubectl get pods -n dotnet-k8s -o wide

# Ingress rules
kubectl get ingress -n dotnet-k8s

# ConfigMaps and Secrets
kubectl get configmap,secret -n dotnet-k8s
```

### Deployment & rollout

```bash
# Check rollout status
kubectl rollout status deployment/todo-app -n dotnet-k8s

# Rolling restart (picks up new image or config)
kubectl rollout restart deployment/todo-app -n dotnet-k8s

# Rollback to previous revision
kubectl rollout undo deployment/todo-app -n dotnet-k8s

# Scale replicas manually
kubectl scale deployment/todo-app --replicas=5 -n dotnet-k8s

# View rollout history
kubectl rollout history deployment/todo-app -n dotnet-k8s
```

### Logs & debugging

```bash
# Logs from all 3 todo-app pods at once
kubectl logs -l app=todo-app -n dotnet-k8s --follow

# Logs from a specific pod
kubectl logs <pod-name> -n dotnet-k8s

# Previous container logs (after a crash)
kubectl logs <pod-name> -n dotnet-k8s --previous

# Describe a pod (events, mounts, env vars)
kubectl describe pod <pod-name> -n dotnet-k8s

# Describe the ingress (check rules and backend health)
kubectl describe ingress todo-app-ingress -n dotnet-k8s

# Exec into a running todo-app pod
kubectl exec -it <pod-name> -n dotnet-k8s -- /bin/sh

# Check what appsettings.json the ConfigMap mounted
kubectl exec -it <pod-name> -n dotnet-k8s -- cat /app/appsettings.json
```

### ConfigMap — update non-sensitive settings

```bash
# Edit in-place (opens $EDITOR / notepad)
kubectl edit configmap todo-app-config -n dotnet-k8s

# Or replace from file after editing k8s/configmap.yaml
kubectl apply -f k8s/configmap.yaml

# Pods must be restarted to pick up the new file mount
kubectl rollout restart deployment/todo-app -n dotnet-k8s
```

### Secret — rotate sensitive values

```bash
# Recreate secret with new values
kubectl create secret generic todo-app-secret \
  --from-literal=ConnectionStrings__DefaultConnection="Host=new-host;Port=5432;Database=todos;Username=app;Password=NewPass!" \
  --from-literal=Postgres__Password="NewPass!" \
  -n dotnet-k8s \
  --dry-run=client -o yaml | kubectl apply -f -

# Restart pods to pick up the new env var
kubectl rollout restart deployment/todo-app -n dotnet-k8s

# Decode a secret value (base64)
kubectl get secret todo-app-secret -n dotnet-k8s \
  -o jsonpath='{.data.Postgres__Password}' | base64 --decode
```

### Ingress & nginx controller

```bash
# Check the Ingress controller service (should show EXTERNAL-IP=localhost on Docker Desktop)
kubectl get svc ingress-nginx-controller -n ingress-nginx

# View nginx Ingress controller logs (useful for 404/502 debugging)
kubectl logs -l app.kubernetes.io/component=controller -n ingress-nginx --follow

# List all Ingress resources across all namespaces
kubectl get ingress -A

# Check ingress controller version
kubectl exec -n ingress-nginx \
  $(kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller -o name) \
  -- /nginx-ingress-controller --version
```

### PostgreSQL (in-cluster)

```bash
# Connect to the Postgres pod directly
kubectl exec -it \
  $(kubectl get pod -n dotnet-k8s -l app=postgres -o name) \
  -n dotnet-k8s -- psql -U app -d todos

# Quick query to check todo rows
kubectl exec -it \
  $(kubectl get pod -n dotnet-k8s -l app=postgres -o name) \
  -n dotnet-k8s -- psql -U app -d todos -c "SELECT id, title, \"isComplete\" FROM \"Todos\";"
```

### Teardown

```bash
# Delete just the app (keep namespace and postgres)
kubectl delete -f k8s/deployment.yaml -f k8s/service.yaml -f k8s/ingress.yaml

# Delete everything in the namespace
kubectl delete namespace dotnet-k8s

# Remove the nginx Ingress controller
kubectl delete -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.0/deploy/static/provider/cloud/deploy.yaml
```

---

## API Endpoints

| Method | Route | Body | Description |
|--------|-------|------|-------------|
| `GET` | `/todos` | — | List all todos |
| `GET` | `/todos/{id}` | — | Get todo by Guid |
| `POST` | `/todos` | `{"title": "..."}` | Create a todo |
| `PUT` | `/todos/{id}` | `{"title": "...", "isComplete": true}` | Update a todo |
| `DELETE` | `/todos/{id}` | — | Delete a todo |

---

## Testing with the HTTP Client

The file `DotnetK8sSetup/todos.http` covers the full CRUD flow.
Environments are defined in `DotnetK8sSetup/http-client.env.json`:

| Environment | `baseUrl` | When to use |
|---|---|---|
| `local` | `http://localhost:5239` | `dotnet run` on your machine |
| `k8s` | `http://todo-app.local` | Deployed to Docker Desktop cluster |

In **Rider**: select the environment from the dropdown in the top-right corner of the `.http` file editor, then click the green ▶ button next to each request.

The response handler blocks (`> {% client.global.set(...) %}`) automatically capture the
created todo `id` and pass it into the subsequent GET / PUT / DELETE requests — no
manual copy-paste required.
