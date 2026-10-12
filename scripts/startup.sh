#!/usr/bin/env bash
# scripts/startup.sh
# Brings up the whole lab: kind cluster -> image -> namespace -> config ->
# Redis -> API, then waits until the API answers on the NodePort.
# Safe to run again at any time: every step checks or converges instead of
# blindly creating things.
#
# Options (environment variables):
#   SKIP_BUILD=1    don't rebuild the Docker image
#   RESTART_API=1   restart the API pods so they pick up a rebuilt image
#
# Usage:  ./scripts/startup.sh
#         RESTART_API=1 ./scripts/startup.sh

set -euo pipefail

# ------------ Settings ------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CLUSTER_NAME="${CLUSTER_NAME:-redis-lab}"
NAMESPACE="${NAMESPACE:-redis-lab}"
IMAGE="${IMAGE:-redis-lab-api:0.1.0}"
KIND_CONFIG="${PROJECT_DIR}/kind-cluster.yaml"
CHART_DIR="${PROJECT_DIR}/charts/redis-lab"
RELEASE="redis-lab"
SECRET_NAME="redis-secret"
PASSWORD_FILE="${PROJECT_DIR}/secrets/redis-password"

PLATFORM_DIR="${PROJECT_DIR}/platform"
GATEWAY_URL="${GATEWAY_URL:-http://localhost}"
GATEWAY_NAMESPACE="traefik"
GATEWAY_NAME="lab-gateway"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.5.1}"

API_SERVICE="redis-lab-api"
SKIP_BUILD="${SKIP_BUILD:-0}"
RESTART_API="${RESTART_API:-0}"
CONTEXT="${CONTEXT:-kind-${CLUSTER_NAME}}"

log()  { printf '\n==> %s\n' "$*"; }
fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# ----------- Prerequisites ------------
log "Checking prerequisites"
for cmd in docker kind kubectl helm curl; do
  command -v "$cmd" >/dev/null 2>&1 || fail "'$cmd' is not installed or not on PATH"
done
docker info >/dev/null 2>&1 \
  || fail "Docker is not running. Start Docker Desktop and check WSL integration."
[[ -f "$KIND_CONFIG" ]] || fail "Missing $KIND_CONFIG"

[[ -f "$CHART_DIR/Chart.yaml" ]] || fail "Missing Helm chart at $CHART_DIR"

if [[ -z "${REDIS_PASSWORD:-}" && -f "$PASSWORD_FILE" ]]; then
  REDIS_PASSWORD="$(tr -d '\r\n' < "$PASSWORD_FILE")"
fi
[[ -n "${REDIS_PASSWORD:-}" ]] || fail "No Redis password. Create it with:
  mkdir -p secrets && openssl rand -hex 16 > secrets/redis-password"

log "Linting the Helm chart"
helm lint "$CHART_DIR" >/dev/null || { helm lint "$CHART_DIR"; fail "helm lint found problems"; }

for f in traefik-values gateway namespaces; do
  [[ -f "$PLATFORM_DIR/$f.yaml" ]] || fail "Missing $PLATFORM_DIR/$f.yaml"
done

# ----------- 2. Cluster (create only if it doesn't exist) ------------
log "Creating kind cluster '$CLUSTER_NAME' (if it doesn't exist)"
if ! kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
    kind create cluster --name "$CLUSTER_NAME" --config "$KIND_CONFIG"
    log "Cluster '$CLUSTER_NAME' created"
else
    log "Cluster '$CLUSTER_NAME' already exists"
fi
kubectl config use-context "$CONTEXT" >/dev/null
log "Waiting for cluster to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null
log "Cluster is ready"

# ----------- 3. Build Docker image ------------
if [[ "$SKIP_BUILD" == "1" ]]; then
    log "Skipping Docker image build (SKIP_BUILD=1)"
else
    log "Building Docker image '$IMAGE'"
    docker build -t "$IMAGE" "$PROJECT_DIR"
    log "Docker image '$IMAGE' built"
fi
docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "Docker image '$IMAGE' not found"
log "Loading Docker image '$IMAGE' into kind cluster '$CLUSTER_NAME'"
kind load docker-image "$IMAGE" --name "$CLUSTER_NAME"

# ----------- Gateway controller (Traefik) and the Gateway ------------
log "Installing the Gateway API CRDs ($GATEWAY_API_VERSION)"
kubectl apply --server-side --force-conflicts -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" >/dev/null
log "Installing/upgrading Traefik (Gateway API controller) with Helm"
helm repo add traefik https://traefik.github.io/charts --force-update >/dev/null
helm repo update traefik >/dev/null
helm upgrade --install traefik traefik/traefik \
  --namespace "$GATEWAY_NAMESPACE" --create-namespace \
  --values "$PLATFORM_DIR/traefik-values.yaml" \
  --wait --timeout 5m

log "Waiting for the Gateway API CRDs"
kubectl wait --for=condition=Established --timeout=60s \
  crd/gatewayclasses.gateway.networking.k8s.io \
  crd/gateways.gateway.networking.k8s.io \
  crd/httproutes.gateway.networking.k8s.io >/dev/null

log "Applying the Gateway '$GATEWAY_NAME'"
kubectl apply -f "$PLATFORM_DIR/gateway.yaml"
kubectl wait --for=condition=Programmed "gateway/$GATEWAY_NAME" \
  -n "$GATEWAY_NAMESPACE" --timeout=120s \
  || fail "Gateway not Programmed. Check: kubectl describe gateway $GATEWAY_NAME -n $GATEWAY_NAMESPACE"

# ---------- 4. Namespace and the Redis password Secret ----------
log "Applying namespaces"
kubectl apply -f "$PLATFORM_DIR/namespaces.yaml"
kubectl wait --for=jsonpath='{.status.phase}'=Active "namespace/$NAMESPACE" --timeout=60s >/dev/null

log "Creating/updating Secret '$SECRET_NAME'"
kubectl create secret generic "$SECRET_NAME" -n "$NAMESPACE" \
  --from-literal=REDIS_PASSWORD="$REDIS_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# ---------- 5. One-time check: objects left over from Stages 4-7 ----------
if kubectl get deploy redis-lab-api -n "$NAMESPACE" >/dev/null 2>&1; then
  owner=$(kubectl get deploy redis-lab-api -n "$NAMESPACE" \
          -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null || true)
  [[ "$owner" == "$RELEASE" ]] || fail "The app was created with kubectl apply, and Helm won't take it over.
One-time fix (resets Redis data):  kubectl delete namespace $NAMESPACE --wait=true"
fi

# ---------- 6. Install/upgrade the app chart ----------
log "Installing/upgrading Helm release '$RELEASE'"
helm upgrade --install "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  --set image.repository="${IMAGE%:*}" \
  --set image.tag="${IMAGE##*:}" \
  --wait --timeout 5m

if [[ "$RESTART_API" == "1" ]]; then
  log "Restarting API pods (RESTART_API=1)"
  kubectl rollout restart deployment/redis-lab-api -n "$NAMESPACE"
  kubectl rollout status deployment/redis-lab-api -n "$NAMESPACE" --timeout=180s
fi

#----------- Verify through the Gateway ------------
log "Waiting for the API at $GATEWAY_URL/api/hits"
ok=0
for _ in $(seq 1 30); do
  if curl -fsS -m 3 -o /dev/null "$GATEWAY_URL/api/hits"; then ok=1; break; fi
  sleep 2
done
[[ "$ok" == "1" ]] || fail "API not reachable through the Gateway. Check:
  kubectl get gateway -n $GATEWAY_NAMESPACE
  kubectl describe httproute $API_SERVICE -n $NAMESPACE
  kubectl get pods -n $GATEWAY_NAMESPACE -o wide"
log "API is reachable through the Gateway"

kubectl get gateway -n "$GATEWAY_NAMESPACE"
kubectl get httproute,svc,deploy,pods -n "$NAMESPACE"
printf '\nLab is ready! Try:\n\n  curl %s/api/hits\n\n' "$GATEWAY_URL"
printf 'Or run the tests: ./scripts/test.sh\n\n'

