#!/usr/bin/env bash
# ============================================================================
# setup-k3d.sh — Create a k3d dev cluster for dotnet-k8s-setup
#
# Automates:
#   1. Check prerequisites (Docker, k3d, kubectl, helm)
#   2. Enable cgroup v2 on WSL2 (Windows-only — auto-detected)
#   3. Create k3d cluster with port mappings for Ingress
#   4. Install nginx Ingress controller
#   5. Build Docker image & import into k3d
#   6. Deploy all Kubernetes manifests
#   7. Add hosts entry for todo-app.local
#
# Usage:
#   ./scripts/setup-k3d.sh              # full setup
#   ./scripts/setup-k3d.sh --skip-build # skip Docker build (use existing image)
#
# Requirements:
#   - Docker Desktop (WSL2 backend on Windows)
#   - k3d v5.x
#   - kubectl
#   - helm  (for ingress-nginx install)
# ============================================================================

set -euo pipefail

# ──────────────────────────────────────────────
# 0. Config
# ──────────────────────────────────────────────
CLUSTER_NAME="dev"
IMAGE_NAME="dotnet-k8s-setup:latest"
INGRESS_VERSION="controller-v1.12.0"
DOMAIN="todo-app.local"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ──────────────────────────────────────────────
# 1. Helper functions
# ──────────────────────────────────────────────
info()  { printf "  ⓘ  %s\n" "$*"; }
ok()    { printf "  ✔  %s\n" "$*"; }
fail()  { printf "  ✘  %s\n" "$*"; exit 1; }
step()  { printf "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n  %s\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n" "$*"; }

# ──────────────────────────────────────────────
# 2. Parse args
# ──────────────────────────────────────────────
SKIP_BUILD=false
for arg in "$@"; do
  [ "$arg" = "--skip-build" ] && SKIP_BUILD=true
done

# ──────────────────────────────────────────────
# 3. Check prerequisites
# ──────────────────────────────────────────────
step "1/8  Checking prerequisites"

command -v docker >/dev/null 2>&1 || fail "Docker not found. Install Docker Desktop first."
docker info --format '{{.ServerVersion}}' >/dev/null 2>&1 || fail "Docker is not running. Start Docker Desktop."
ok "Docker $(docker info --format '{{.ServerVersion}}')"

command -v k3d >/dev/null 2>&1 || fail "k3d not found. Install: 'brew install k3d' or 'choco install k3d'"
ok "k3d $(k3d version 2>&1 | head -1)"

command -v kubectl >/dev/null 2>&1 || fail "kubectl not found. Install from https://kubernetes.io/docs/tasks/tools/"
ok "kubectl $(kubectl version --client -o json 2>/dev/null | grep -o '"gitVersion":"[^"]*"' | cut -d'"' -f4)"

command -v helm >/dev/null 2>&1 || fail "helm not found. Install: 'brew install helm' or 'choco install kubernetes-helm'"
ok "helm $(helm version --short 2>/dev/null | grep -o 'v[^+]*')"

# ──────────────────────────────────────────────
# 4. Enable cgroup v2 on WSL2 (Windows only)
# ──────────────────────────────────────────────
step "2/8  Enabling cgroup v2 on WSL2"

if grep -qi microsoft /proc/version 2>/dev/null; then
  WSL_CONFIG="$HOME/.wslconfig"
  CGROUP_LINE="kernelCommandLine = cgroup_no_v1=all  # Enable cgroup v2"

  if [ -f "$WSL_CONFIG" ] && grep -q "cgroup_no_v1=all" "$WSL_CONFIG" 2>/dev/null; then
    ok "cgroup v2 already configured in .wslconfig"
  else
    printf "\n%s\n" "$CGROUP_LINE" >> "$WSL_CONFIG"
    ok "Added cgroup v2 setting to $WSL_CONFIG"
    info "Shutting down WSL to apply change..."
    wsl --shutdown
    info "Restarting Docker Desktop..."
    # Docker Desktop restart — tell user to do it manually & wait
    if ! docker info 2>/dev/null >/dev/null; then
      echo ""
      echo "  ⚠  Docker Desktop needs to restart to apply cgroup v2."
      echo "     Please manually restart Docker Desktop now, then re-run this script."
      echo ""
      exit 0
    fi
  fi

  # Verify cgroup v2
  DOCKER_CGROUP=$(docker info --format '{{.CgroupVersion}}' 2>/dev/null || echo "1")
  if [ "$DOCKER_CGROUP" != "2" ]; then
    fail "cgroup v2 not active. Restart Docker Desktop and try again."
  fi
  ok "cgroup v2 verified (Docker cgroup version: $DOCKER_CGROUP)"
else
  info "Not running on WSL2 — skipping cgroup v2 config"
fi

# ──────────────────────────────────────────────
# 5. Delete existing cluster if present, then create
# ──────────────────────────────────────────────
step "3/8  Creating k3d cluster '$CLUSTER_NAME'"

if k3d cluster list 2>/dev/null | grep -q "^$CLUSTER_NAME"; then
  info "Cluster '$CLUSTER_NAME' already exists. Deleting..."
  k3d cluster delete "$CLUSTER_NAME"
fi

k3d cluster create "$CLUSTER_NAME" \
  --servers 1 \
  --agents 0 \
  -p "80:80@loadbalancer" \
  -p "443:443@loadbalancer"

ok "Cluster '$CLUSTER_NAME' created"

# Merge kubeconfig & switch context
k3d kubeconfig merge "$CLUSTER_NAME" \
  --kubeconfig-merge-default \
  --kubeconfig-switch-context \
  >/dev/null 2>&1 || true

# Fix 0.0.0.0 → 127.0.0.1 in kubeconfig (Windows compat)
kubectl config set-cluster "k3d-$CLUSTER_NAME" \
  --server="https://127.0.0.1:$(kubectl config view -o jsonpath="{.clusters[?(@.name=='k3d-$CLUSTER_NAME')].cluster.server}" | grep -oP '\d+$')" \
  --insecure-skip-tls-verify=true \
  >/dev/null 2>&1 || true

ok "Kubeconfig merged & context switched to k3d-$CLUSTER_NAME"

# ──────────────────────────────────────────────
# 6. Install nginx Ingress Controller
# ──────────────────────────────────────────────
step "4/8  Installing nginx Ingress Controller"

helm upgrade --install ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.hostNetwork=true \
  --set controller.service.type=ClusterIP \
  --wait \
  --timeout 3m

# Patch to use hostNetwork:true on the controller pod and wait for readiness
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s 2>/dev/null || true

# Double-check via rollout status
kubectl rollout status deployment/ingress-nginx-controller \
  -n ingress-nginx --timeout=120s 2>/dev/null && \
  ok "nginx Ingress Controller installed" || \
  info "Ingress controller still starting — will be ready shortly"

# ──────────────────────────────────────────────
# 7. Build Docker image and import into k3d
# ──────────────────────────────────────────────
step "5/8  Building Docker image & importing into k3d"

if [ "$SKIP_BUILD" = true ]; then
  info "Skipping Docker build (--skip-build)"
else
  cd "$REPO_ROOT"

  # Build the Docker image
  docker build -t "$IMAGE_NAME" .
  ok "Image '$IMAGE_NAME' built"

  # Import into k3d so the cluster can use it
  k3d image import "$IMAGE_NAME" -c "$CLUSTER_NAME"
  ok "Image imported into k3d cluster '$CLUSTER_NAME'"
fi

# ──────────────────────────────────────────────
# 8. Deploy Kubernetes manifests
# ──────────────────────────────────────────────
step "6/8  Deploying Kubernetes manifests"

cd "$REPO_ROOT"

kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/secret.yaml
kubectl apply -f k8s/configmap.yaml
kubectl apply -f k8s/postgres.yaml
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
kubectl apply -f k8s/ingress.yaml
ok "All manifests applied"

info "Waiting for rollout..."
kubectl rollout status deployment/todo-app \
  -n dotnet-k8s --timeout=120s 2>/dev/null || \
  info "Rollout still in progress — run 'kubectl get pods -n dotnet-k8s' to check"

# ──────────────────────────────────────────────
# 9. Add hosts entry for todo-app.local
# ──────────────────────────────────────────────
step "7/8  Adding hosts entry for $DOMAIN"

add_hosts_entry() {
  local HOSTS_FILE="$1"
  if grep -q "$DOMAIN" "$HOSTS_FILE" 2>/dev/null; then
    ok "$DOMAIN already in $HOSTS_FILE"
  else
    echo "127.0.0.1 $DOMAIN" >> "$HOSTS_FILE" 2>/dev/null && \
      ok "Added $DOMAIN → 127.0.0.1 to $HOSTS_FILE" || \
      info "Could not write to $HOSTS_FILE — add manually:"
    info "  echo '127.0.0.1 $DOMAIN' | sudo tee -a $HOSTS_FILE"
  fi
}

case "$(uname -s)" in
  Linux)  add_hosts_entry "/etc/hosts" ;;
  Darwin) add_hosts_entry "/etc/hosts" ;;
  MINGW*|MSYS*|CYGWIN*)
    HOSTS_FILE="/c/Windows/System32/drivers/etc/hosts"
    if [ -f "$HOSTS_FILE" ]; then
      add_hosts_entry "$HOSTS_FILE"
    else
      info "Run this as Administrator to add hosts entry:"
      info "  Add-Content -Path \"C:\\Windows\\System32\\drivers\\etc\\hosts\" -Value \"127.0.0.1 $DOMAIN\""
    fi
    ;;
esac

# ──────────────────────────────────────────────
# 10. Done — print summary
# ──────────────────────────────────────────────
step "8/8  Setup complete!"

echo "  ┌─────────────────────────────────────────────────────┐"
echo "  │                                                     │"
echo "  │   🚀  k3d cluster '$CLUSTER_NAME' is ready!           │"
echo "  │                                                     │"
echo "  │   App URL:  http://$DOMAIN/todos                    │"
echo "  │                                                     │"
echo "  │   Useful commands:                                  │"
echo "  │     kubectl get pods -n dotnet-k8s                  │"
echo "  │     kubectl get ingress -n dotnet-k8s               │"
echo "  │     kubectl logs -n dotnet-k8s deploy/todo-app      │"
echo "  │     k3d cluster list                                │"
echo "  │                                                     │"
echo "  │   Clean up:                                         │"
echo "  │     k3d cluster delete $CLUSTER_NAME                 │"
echo "  │                                                     │"
echo "  └─────────────────────────────────────────────────────┘"
