#!/usr/bin/env bash
# MaaS 알려진 문제 조치(RHOAI-Toolkit docs/bugs·install-rhoai-34.sh configure_maas_rate_limiting을 폐쇄망용으로 옮김)
#   1) default-tenant gatewayRef → maas-default-gateway  (3.4: API Keys 화면 404, maas-api-route 미연결)      MAAS_FIX_TENANT
#   2) Limitador redis-cached 저장소 + Redis 1개                (토큰 한도 카운터 유지·배치 반영)              MAAS_REDIS
#   3) EnvoyFilter healthcheck-filter·ratelimit timeout 2s       (Wasm span buffer 포화로 토큰 한도 미동작)      MAAS_ENVOYFILTERS
#   스크립트 실행용 이미지: REDIS_IMAGE(mirror/runtime-images.txt). 선행: 60-rhcl.sh, 62-maas.sh
#   이미 있는 리소스는 변경하지 않는다. 원복: docs/90-troubleshooting.md "63-maas-fixes 원복"
source "$(dirname "$0")/lib/common.sh"
init
is_on "$FEATURE_MAAS" || { log "FEATURE_MAAS=false: 건너뜁니다."; exit 0; }
GW=maas-default-gateway

step "1. default-tenant gatewayRef"
if ! is_on "$MAAS_FIX_TENANT"; then log "MAAS_FIX_TENANT=false"
elif ! has_crd tenants.maas.opendatahub.io; then
  log "tenants.maas.opendatahub.io 없음(3.5는 MaaSTenantConfig 사용) — 건너뜁니다."
else
  CUR=$(oc get tenants.maas.opendatahub.io default-tenant -n models-as-a-service -o jsonpath='{.spec.gatewayRef.namespace}/{.spec.gatewayRef.name}' 2>/dev/null || true)
  if [[ -z "$CUR" || "$CUR" == "/" ]]; then
    warn "default-tenant 없음 — 62-maas.sh 이후 다시 실행"
  elif [[ "$CUR" == "openshift-ingress/$GW" ]]; then
    ok "gatewayRef=$CUR"
  else
    backup tenants.maas.opendatahub.io default-tenant models-as-a-service
    confirm "default-tenant gatewayRef를 $CUR → openshift-ingress/$GW로 바꿉니까?"
    k_patch tenants.maas.opendatahub.io default-tenant models-as-a-service merge \
      "{\"spec\":{\"gatewayRef\":{\"name\":\"$GW\",\"namespace\":\"openshift-ingress\"}}}"
  fi
fi

step "2. Limitador redis-cached"
if ! is_on "$MAAS_REDIS"; then log "MAAS_REDIS=false"
elif ! oc get limitador limitador -n kuadrant-system >/dev/null 2>&1; then
  warn "Limitador/limitador 없음 — 60-rhcl.sh 이후 다시 실행"
elif [[ -n "$(oc get limitador limitador -n kuadrant-system -o jsonpath='{.spec.storage}' 2>/dev/null)" ]]; then
  ok "Limitador storage 이미 지정됨: $(oc get limitador limitador -n kuadrant-system -o jsonpath='{.spec.storage}' | jq -c 'keys') — 변경하지 않습니다."
else
  f="$EVIDENCE_DIR/limitador-redis.yaml"
  cat >"$f" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: limitador-redis
  namespace: kuadrant-system
  labels: {app: limitador-redis}
spec:
  replicas: 1
  selector: {matchLabels: {app: limitador-redis}}
  template:
    metadata: {labels: {app: limitador-redis}}
    spec:
      containers:
      - name: redis
        image: ${REDIS_IMAGE}
        ports: [{containerPort: 6379}]
        resources:
          requests: {cpu: 100m, memory: 128Mi}
          limits: {cpu: 500m, memory: 256Mi}
---
apiVersion: v1
kind: Service
metadata:
  name: limitador-redis
  namespace: kuadrant-system
spec:
  selector: {app: limitador-redis}
  ports: [{port: 6379, targetPort: 6379}]
---
# Redis는 인증이 없으므로 같은 namespace(kuadrant-system, Limitador)에서만 접근을 허용한다.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: limitador-redis
  namespace: kuadrant-system
spec:
  podSelector: {matchLabels: {app: limitador-redis}}
  policyTypes: [Ingress]
  ingress:
  - from:
    - podSelector: {}
    ports: [{port: 6379, protocol: TCP}]
EOF
  backup limitador limitador kuadrant-system
  confirm "Redis(${REDIS_IMAGE})를 만들고 Limitador를 redis-cached로 바꿉니까?"
  k_apply "$f"
  wait_for "limitador-redis Ready" 300 oc rollout status deploy/limitador-redis -n kuadrant-system --timeout=10s \
    || die "Redis가 Ready가 아닙니다(이미지 반입 확인: ./bc-toolkit.sh images). Limitador는 바꾸지 않았습니다."
  put_secret limitador-redis-config kuadrant-system "URL=redis://limitador-redis.kuadrant-system.svc.cluster.local:6379"
  k_patch limitador limitador kuadrant-system merge \
    '{"spec":{"storage":{"redis-cached":{"configSecretRef":{"name":"limitador-redis-config"},"options":{"flush-period":500,"max-cached":10000,"batch-size":100,"response-timeout":500}}}}}'
fi

step "3. EnvoyFilter"
RESTART=false
if ! is_on "$MAAS_ENVOYFILTERS"; then log "MAAS_ENVOYFILTERS=false"
elif ! has_crd envoyfilters.networking.istio.io; then warn "EnvoyFilter CRD 없음 — 건너뜁니다."
else
  for ef in healthcheck-filter increase-ratelimit-cluster-timeout; do
    if oc get envoyfilter "$ef" -n openshift-ingress >/dev/null 2>&1; then ok "EnvoyFilter/$ef 이미 있음"; continue; fi
    f="$EVIDENCE_DIR/envoyfilter-$ef.yaml"
    if [[ "$ef" == healthcheck-filter ]]; then
      cat >"$f" <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: healthcheck-filter
  namespace: openshift-ingress
spec:
  workloadSelector:
    labels:
      gateway.networking.k8s.io/gateway-name: ${GW}
  configPatches:
    - applyTo: HTTP_FILTER
      match:
        context: GATEWAY
        listener:
          filterChain:
            filter:
              name: envoy.filters.network.http_connection_manager
      patch:
        operation: INSERT_FIRST
        value:
          name: envoy.filters.http.health_check
          typed_config:
            "@type": type.googleapis.com/envoy.extensions.filters.http.health_check.v3.HealthCheck
            pass_through_mode: false
            headers:
              # headers 항목은 AND 조건이라 경로 두 개를 한 정규식으로 묶는다.
              - name: ":path"
                string_match:
                  safe_regex:
                    regex: "^/(healthz|ready)$"
EOF
    else
      cat >"$f" <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: increase-ratelimit-cluster-timeout
  namespace: openshift-ingress
spec:
  workloadSelector:
    labels:
      gateway.networking.k8s.io/gateway-name: ${GW}
  configPatches:
    - applyTo: CLUSTER
      match:
        context: GATEWAY
        cluster:
          name: kuadrant-ratelimit-service
      patch:
        operation: MERGE
        value:
          connect_timeout: 2s
EOF
    fi
    confirm "EnvoyFilter/$ef(openshift-ingress, $GW 전용)를 만듭니까?"
    k_apply "$f"
    RESTART=true
  done
fi
if [[ "$RESTART" == true ]] && ! is_dry_run; then
  D=$(oc get deploy -n openshift-ingress -l "gateway.networking.k8s.io/gateway-name=$GW" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -n "$D" ]]; then
    confirm "$GW Pod($D)를 재기동합니까? (MaaS 호출이 잠시 끊긴다)"
    oc rollout restart "deploy/$D" -n openshift-ingress
    oc rollout status "deploy/$D" -n openshift-ingress --timeout=300s
  fi
fi
log "확인: 같은 API key로 한도 초과 호출 시 429, oc get envoyfilter -n openshift-ingress, oc get limitador limitador -n kuadrant-system -o jsonpath='{.spec.storage}'"
