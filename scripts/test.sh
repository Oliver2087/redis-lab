#!/usr/bin/env bash
# scripts/test.sh
# Checks that the cluster objects are healthy and the API behaves correctly.
# Runs every check, prints PASS/FAIL for each, and exits with code 1 if any
# check failed (so CI pipelines can use it later).
#
# Usage:  ./scripts/test.sh            normal checks
#         ./scripts/test.sh --chaos    also deletes the Redis pod and checks
#                                      that data survives (persistence test)
 
set -uo pipefail   # no "-e": a failed check must not stop the other checks

NAMESPACE="${NAMESPACE:-redis-lab}"
BASE_URL="${BASE_URL:-http://localhost}"
OLD_NODEPORT_URL="http://localhost:30080"
API_SERVICE="redis-lab-api"
GATEWAY_NAMESPACE="traefik"
GATEWAY_NAME="lab-gateway"
EXPECTED_CONTEXT="${EXPECTED_CONTEXT:-kind-redis-lab}"
CHAOS=0
[[ "${1:-}" == "--chaos" ]] && CHAOS=1

PASS=0
FAIL=0
pass() { printf '\nPASS: %s\n' "$*"; PASS=$((PASS + 1)); }
failc() {
  printf '  FAIL  %s\n' "$1"
  [[ -n "${2:-}" ]] && printf '        %s\n' "$2"
  FAIL=$((FAIL + 1))
}
section() { printf '\n%s\n' "$1"; }
is_int() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

# Request METHOD URL [JSON_BODY] -> sets STATUS and BODY variables
request() {
  local method="$1" url="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    BODY="$(curl -s -w "\n%{http_code}" -X "$method" -H "Content-Type: application/json" -d "$body" "$url")"
  else
    BODY="$(curl -s -w "\n%{http_code}" -X "$method" "$url")"
  fi
  STATUS="$(tail -n1 <<<"$BODY")"
  BODY="$(sed '$d' <<<"$BODY")"
}


# json_get FIELD -> prints a field from $BODY (empty if missing or not JSON)
json_get() {
  python3 -c 'import sys, json; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$1" <<<"$BODY" 2>/dev/null || true
}

# ----------- 1. Cluster checks ------------
section "1. Cluster checks"
CTX="$(kubectl config current-context 2>/dev/null || true)"
if [[ "$CTX" == "$EXPECTED_CONTEXT" ]]; then
  pass "kubectl context is '$CTX'"
else
  failc "kubectl context is '$CTX', expected '$EXPECTED_CONTEXT'"
fi

for d in redis redis-lab-api; do
    WANT=$(kubectl get deploy "$d" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    READY=$(kubectl get deploy "$d" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [[ "$WANT" == "$READY" ]]; then
        pass "Deployment $d has $READY/$WANT pods ready"
    else
    failc "Deployment $d has ${READY:-0}/${WANT:-?} pods ready" \
          "Check: kubectl get pods -n $NAMESPACE"
    fi
done

PVC=$(kubectl get pvc redis-data -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Missing")
if [[ "$PVC" == "Bound" ]]; then
    pass "PVC redis-data is Bound"
else
    failc "PVC redis-data is $PVC" \
          "Check: kubectl get pvc -n $NAMESPACE"
fi

# Service should now be internal-only (ClusterIP), not NodePort, so we check that the old NodePort URL is not reachable.
SVC_TYPE=$(kubectl get svc "$API_SERVICE" -n "$NAMESPACE" -o jsonpath='{.spec.type}' 2>/dev/null || echo "Missing")
SVC_PORT=$(kubectl get svc "$API_SERVICE" -n "$NAMESPACE" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "Missing")
if [[ "$SVC_TYPE" == "ClusterIP" && "$SVC_PORT" == "80" ]]; then
    pass "Service $API_SERVICE is ClusterIP on port 80"
else
    failc "Service $API_SERVICE is $SVC_TYPE on port $SVC_PORT" \
          "Check: kubectl get svc $API_SERVICE -n $NAMESPACE"
fi

# The Service should route to as many Pods as the Deployment wants, so we check that the number of endpoints matches the Deployment's replicas.
WANT_API=$(kubectl get deploy redis-lab-api -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
EPS=$(kubectl get endpointslices -n "$NAMESPACE" -l "kubernetes.io/service-name=$API_SERVICE" \
      -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{"\n"}{end}' 2>/dev/null | grep -c . || true)

if [[ -n "$EPS" && "$EPS" == "$WANT_API" ]]; then
    pass "Service $API_SERVICE has $EPS endpoints (matches Deployment replicas)"
else
    failc "Service $API_SERVICE has $EPS endpoints (expected $WANT_API)" \
          "Check: kubectl get endpointslices -n $NAMESPACE -l kubernetes.io/service-name=$API_SERVICE"
fi

# The old NodePort URL should not be reachable anymore, since the Service is now ClusterIP.
OLD_STATUS="$(curl -s -m 3 -o /dev/null -w '%{http_code}' "$OLD_NODEPORT_URL/" || true)"
if [[ "$OLD_STATUS" == "000" ]]; then
    pass "Old NodePort URL $OLD_NODEPORT_URL is not reachable (as expected)"
else
    failc "Old NodePort URL $OLD_NODEPORT_URL is reachable (status $OLD_STATUS)" \
          "Check: kubectl get svc $API_SERVICE -n $NAMESPACE"
fi

# ----------- 2. Gateway API checks ------------
section "2. Gateway API checks"

T_WANT=$(kubectl get deploy traefik -n "$GATEWAY_NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)
T_READY=$(kubectl get deploy traefik -n "$GATEWAY_NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
if [[ -n "$T_WANT" && "$T_WANT" == "${T_READY:-0}" ]]; then
  pass "Traefik controller has $T_READY/$T_WANT pods ready"
else
  failc "Traefik controller has ${T_READY:-0}/${T_WANT:-?} pods ready" \
        "Check: kubectl get pods -n $GATEWAY_NAMESPACE -o wide"
fi

GC=$(kubectl get gatewayclass traefik \
     -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
if [[ "$GC" == "True" ]]; then
  pass "GatewayClass traefik is Accepted"
else
  failc "GatewayClass traefik Accepted='${GC:-missing}'" \
        "Check: kubectl describe gatewayclass traefik"
fi

GW=$(kubectl get gateway "$GATEWAY_NAME" -n "$GATEWAY_NAMESPACE" \
     -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)
if [[ "$GW" == "True" ]]; then
  pass "Gateway $GATEWAY_NAME is Programmed"
else
  failc "Gateway $GATEWAY_NAME Programmed='${GW:-missing}'" \
        "Check: kubectl describe gateway $GATEWAY_NAME -n $GATEWAY_NAMESPACE"
fi

RT_ACC=$(kubectl get httproute "$API_SERVICE" -n "$NAMESPACE" \
         -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
RT_REF=$(kubectl get httproute "$API_SERVICE" -n "$NAMESPACE" \
         -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}' 2>/dev/null || true)
if [[ "$RT_ACC" == "True" && "$RT_REF" == "True" ]]; then
  pass "HTTPRoute $API_SERVICE is Accepted and its backend is resolved"
else
  failc "HTTPRoute $API_SERVICE Accepted='${RT_ACC:-missing}' ResolvedRefs='${RT_REF:-missing}'" \
        "Check: kubectl describe httproute $API_SERVICE -n $NAMESPACE"
fi

# ----------- 3. API checks ------------
section "3. API checks"

request GET "$BASE_URL/"
if [[ "$STATUS" == "200" && "$(json_get redis_host)" == "redis" ]]; then
  pass "GET / returns 200 and redis_host=redis"
else
  failc "GET / returned $STATUS" "Body: $BODY"
fi
 
request GET "$BASE_URL/api/hits"; first=$(json_get hits)
request GET "$BASE_URL/api/hits"; second=$(json_get hits)
if is_int "$first" && is_int "$second" && (( second > first )); then
  pass "GET /api/hits increments ($first -> $second)"
else
  failc "GET /api/hits did not increment (got '$first' then '$second', status $STATUS)" \
        "Body: $BODY"
fi

key="test-key-$(date +%s)"
value="hello-$RANDOM"
request PUT "$BASE_URL/api/items/$key" "{\"value\":\"$value\"}"
if [[ "$STATUS" == "200" ]]; then
  pass "PUT /api/items/$key returns 200"
else
  failc "PUT /api/items/$key returned $STATUS" "Body: $BODY"
fi

request GET "$BASE_URL/api/items/$key"
if [[ "$STATUS" == "200" && "$(json_get value)" == "$value" ]]; then
  pass "GET /api/items/$key returns 200 and value=$value"
else
  failc "GET /api/items/$key returned $STATUS" "Body: $BODY"
fi

request GET "$BASE_URL/api/items/nonexistent"
if [[ "$STATUS" == "404" ]]; then
  pass "GET /api/items/nonexistent returns 404"
else
  failc "GET /api/items/nonexistent returned $STATUS" "Body: $BODY"
fi

# /docs exists in the app, but the HTTPRoute does not route it, so the
# Gateway itself should answer 404 (plain text, not the app's JSON).
request GET "$BASE_URL/docs"
if [[ "$STATUS" == "404" && -z "$(json_get detail)" ]]; then
  pass "GET /docs is not routed, so the Gateway answers 404"
else
  failc "GET /docs returned $STATUS, expected a Gateway 404" "Body: $BODY"
fi

#----------- 4. Chaos test (optional) ------------
if [[ "$CHAOS" == "1" ]]; then
  section "4. Chaos test: delete Redis pod and check data persistence"
  pod=$(kubectl get pods -n "$NAMESPACE" -l app=redis \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [[ -z "$pod" ]]; then
    failc "No Redis pod found to delete"
  elif ! kubectl delete pod "$pod" -n "$NAMESPACE" --wait=true >/dev/null; then
    failc "Could not delete Redis pod $pod"
  else
    printf '  Deleted Redis pod %s; waiting for its replacement...\n' "$pod"
    replacement_pod=""
    for ((attempt = 1; attempt <= 30; attempt++)); do
      replacement_pod=$(kubectl get pods -n "$NAMESPACE" -l app=redis \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
      [[ -n "$replacement_pod" ]] && break
      sleep 1
    done

    if [[ -z "$replacement_pod" ]]; then
      failc "Redis replacement pod was not created"
    elif ! kubectl wait --for=condition=Ready pod -l app=redis \
      -n "$NAMESPACE" --timeout=120s >/dev/null; then
      failc "Redis replacement pod did not become Ready"
    else
      api_ready=0
      for ((attempt = 1; attempt <= 15; attempt++)); do
        request GET "$BASE_URL/api/items/$key"
        if [[ "$STATUS" == "200" ]]; then
          api_ready=1
          break
        fi
        sleep 2
      done

      if [[ "$api_ready" == "1" && "$(json_get value)" == "$value" ]]; then
        pass "After Redis pod restart, GET /api/items/$key still returns 200 and value=$value"
      elif [[ "$api_ready" != "1" ]]; then
        failc "API did not recover after the Redis pod restart (last status: $STATUS)"
      else
        failc "After Redis pod restart, GET /api/items/$key returned an unexpected value" \
          "Body: $BODY"
      fi
    fi
  fi
fi

# ---------- Summary ----------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1