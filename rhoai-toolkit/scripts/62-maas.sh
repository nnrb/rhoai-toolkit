#!/usr/bin/env bash
# Models-as-a-Service 활성화
#   1) maas-default-gateway(ClusterIP + passthrough Route)  2) DSC MaaS 컴포넌트(버전별 경로)
#   3) maas-api 기동·DB Secret 확인  4) Dashboard MaaS 메뉴  5) 호출 확인
#   선행: 60-rhcl.sh(Kuadrant), 61-maas-db.sh(maas-db-config)
source "$(dirname "$0")/lib/common.sh"
init envsubst curl
check_version_match

is_on "$FEATURE_MAAS" || { log "FEATURE_MAAS=false: 건너뜁니다."; exit 0; }
MAAS_HOST=${MAAS_HOSTNAME:-maas.$(apps_domain)}

step "1. 전제 조건"
if ! is_dry_run; then
  [[ "$(oc get kuadrant kuadrant -n kuadrant-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == "True" ]] \
    || die "Kuadrant가 Ready가 아닙니다. 60-rhcl.sh를 확인하세요."
  oc get secret maas-db-config -n "$MAAS_DB_NS" >/dev/null 2>&1 \
    || die "maas-db-config Secret이 없습니다($MAAS_DB_NS). 61-maas-db.sh를 먼저 실행하세요."
fi
# User Workload Monitoring이 꺼져 있으면 MaaS가 Degraded가 된다.
if uwm_enabled; then ok "User Workload Monitoring"; else warn "User Workload Monitoring이 꺼져 있습니다. 21-observability.sh로 켜세요(MaaS Degraded 원인)."; fi
ok "MaaS hostname: $MAAS_HOST"

step "2. maas-default-gateway"
# 이 단계부터 클러스터를 바꾼다(TLS Secret·Gateway·namespace label·DSC). 한 번 확인한다.
confirm "MaaS Gateway·TLS Secret·Gateway 접근 label·DSC MaaS($VERSION_LABEL)를 적용합니까?"
if GW_CLASS=$(detect_gateway_class); then ok "GatewayClass: $GW_CLASS"; else
  apply_template "$TOOLKIT_ROOT/manifests/gateway/gatewayclass.yaml"; GW_CLASS=openshift-default
fi
GW_NAME=maas-default-gateway
GW_HOST=$MAAS_HOST
GW_TLS_SECRET=$MAAS_TLS_SECRET
# managed=false: RHOAI가 이 Gateway를 덮어쓰지 않게 한다. authorino-tls-bootstrap: Gateway→Authorino TLS 구성
GW_ANNOTATIONS='{"opendatahub.io/managed":"false","security.opendatahub.io/authorino-tls-bootstrap":"true"}'
export GW_NAME GW_CLASS GW_HOST GW_TLS_SECRET GW_ANNOTATIONS GATEWAY_ACCESS_LABEL
ensure_tls_secret "$GW_TLS_SECRET" openshift-ingress "$MAAS_TLS_CERT_FILE" "$MAAS_TLS_KEY_FILE"
if oc get gateway "$GW_NAME" -n openshift-ingress >/dev/null 2>&1; then
  ok "Gateway/$GW_NAME 이미 존재 — 변경하지 않습니다."
else
  apply_template "$TOOLKIT_ROOT/manifests/gateway/gateway-clusterip.yaml" "$GW_NAME"
fi
wait_for "Gateway $GW_NAME Programmed" 300 \
  oc wait --for=condition=Programmed "gateway/$GW_NAME" -n openshift-ingress --timeout=10s || true
# maas-api HTTPRoute가 붙을 namespace(RHOAIENG-83207: label이 없으면 API Keys 화면 오류)
sync_gateway_access_label "$GW_NAME"
label_gateway_access "$AI_NS"
label_model_namespaces

step "3. DSC MaaS 활성화 ($VERSION_LABEL)"
mapfile -t ITEMS < <(filter_items datasciencecluster "$DSC_API" spec.components "${MAAS_DSC_ITEMS[@]}")
((${#ITEMS[@]} > 0)) || die "이 클러스터 스키마에 MaaS DSC 경로(${MAAS_DSC_ITEMS[*]})가 없습니다. RHOAI_VERSION을 확인하세요."
backup datasciencecluster "$DSC_NAME"
log "DSC MaaS 항목: ${ITEMS[*]}"
k_patch datasciencecluster "$DSC_NAME" "" merge "$(build_patch spec.components "${ITEMS[@]}")"

step "4. maas-api"
if ! is_dry_run; then
  # maas-api가 있는 namespace 목록(3.4→3.5 업그레이드 직후에는 3.4 위치의 maas-api가 남아 있을 수 있다)
  maas_api_nss() { oc get deploy -A -o json | jq -r '.items[] | select(.metadata.name == "maas-api") | .metadata.namespace'; }
  INFRA_NS=""
  if [[ "$RHOAI_VERSION" == 3.5* ]]; then
    # 3.5: DB Secret·maas-api는 infra namespace(MaaSTenantConfig status.infraNamespace, 기본 redhat-ai-gateway-infra) 기준
    infra_ns() { oc get maastenantconfigs.maas.opendatahub.io -A -o jsonpath='{.items[0].status.infraNamespace}' 2>/dev/null; }
    wait_for "MaaSTenantConfig infraNamespace" 600 bash -c "[[ -n \"\$(oc get maastenantconfigs.maas.opendatahub.io -A -o jsonpath='{.items[0].status.infraNamespace}' 2>/dev/null)\" ]]" || true
    INFRA_NS=$(infra_ns || true)
    [[ -n "$INFRA_NS" ]] || die "MaaSTenantConfig status.infraNamespace가 비어 있습니다: oc get maastenantconfigs -A -o yaml"
    ok "MaaS infra namespace: $INFRA_NS"
    wait_for "maas-api Deployment($INFRA_NS)" 600 oc get deploy maas-api -n "$INFRA_NS" || true
  else
    wait_for "maas-api Deployment 생성" 600 bash -c "oc get deploy -A -o json | jq -e '[.items[] | select(.metadata.name == \"maas-api\")] | length > 0'" || true
  fi
  NSS=$(maas_api_nss | xargs)
  if [[ -n "$INFRA_NS" && " $NSS " == *" $INFRA_NS "* ]]; then API_NS=$INFRA_NS
  else API_NS=$(tr ' ' '\n' <<<"$NSS" | grep -vx "$AI_NS" | head -n1 || true); API_NS=${API_NS:-${NSS%% *}}
  fi
  [[ -n "$API_NS" ]] || die "maas-api Deployment가 생성되지 않았습니다: oc get dsc $DSC_NAME -o yaml 의 MaaS condition 확인"
  [[ "$(wc -w <<<"$NSS")" -le 1 ]] || warn "maas-api가 여러 namespace에 있습니다($NSS) → $API_NS 기준으로 확인(이전 버전 maas-api 정리 여부는 담당자 확인)"
  ok "maas-api namespace: $API_NS"
  # maas-api HTTPRoute가 붙는 namespace에도 Gateway 접근 label을 붙인다.
  for t in "$API_NS" ${INFRA_NS:-}; do [[ "$t" == "$AI_NS" ]] || label_gateway_access "$t"; done
  SRC_DATA=$(oc get secret maas-db-config -n "$MAAS_DB_NS" -o jsonpath='{.data.DB_CONNECTION_URL}')
  for target in ${INFRA_NS:-} "$API_NS"; do
    [[ "$target" != "$MAAS_DB_NS" ]] || continue
    # 없거나 내용이 다르면(61을 다시 실행해 URL이 바뀐 경우) 복사한다.
    if [[ "$(oc get secret maas-db-config -n "$target" -o jsonpath='{.data.DB_CONNECTION_URL}' 2>/dev/null || true)" != "$SRC_DATA" ]]; then
      log "maas-db-config를 $target 로 복사"
      oc get secret maas-db-config -n "$MAAS_DB_NS" -o json \
        | jq 'del(.metadata.namespace, .metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.managedFields, .metadata.ownerReferences)' \
        | oc apply -n "$target" -f - >/dev/null
      RESTART_API=true
    fi
  done
  unset SRC_DATA
  if is_on "${RESTART_API:-false}"; then oc rollout restart deployment/maas-api -n "$API_NS"; fi
  oc rollout status deployment/maas-api -n "$API_NS" --timeout=600s \
    || die "maas-api가 Ready가 아닙니다: oc logs deploy/maas-api -n $API_NS (DB 접속 오류면 TS-01/TS-17)"
fi
maas_ready() { [[ "$(dsc_condition_match "$MAAS_READY_REGEX")" == *"=True" ]]; }
wait_for "DSC MaaS condition" 600 maas_ready \
  || warn "MaaS condition이 True가 아닙니다($(dsc_condition_match "$MAAS_READY_REGEX")). oc get dsc $DSC_NAME -o yaml 로 메시지를 확인하세요."

step "5. Dashboard MaaS 메뉴"
collect DITEMS version_maas_dashboard_items
mapfile -t DITEMS < <(filter_items odhdashboardconfig "" spec.dashboardConfig "${DITEMS[@]}")
if ((${#DITEMS[@]} > 0)); then
  backup odhdashboardconfig "$DASH_NAME" "$AI_NS"
  k_patch odhdashboardconfig "$DASH_NAME" "$AI_NS" merge "$(build_patch spec.dashboardConfig "${DITEMS[@]}")"
fi

step "6. 호출 확인"
if ! is_dry_run; then
  TOKEN=$(oc whoami -t 2>/dev/null || true)
  if [[ -z "$TOKEN" ]]; then
    warn "oc whoami -t 실패(인증서 기반 로그인). 사용자 토큰으로 로그인 후 확인하세요(TS-04)."
  else
    CODE=$(curl -sk -o /dev/null -w '%{http_code}' -K <(bearer "$TOKEN") "https://${MAAS_HOST}/maas-api/v1/models" || true)
    case "$CODE" in
      200) ok "GET /maas-api/v1/models → 200" ;;
      401|403) warn "→ $CODE 인증 실패: Authorino TLS/RBAC 확인(TS-05, TS-19)" ;;
      503) warn "→ 503 Route/Gateway 연결 확인(TS-02)" ;;
      *) warn "→ ${CODE:-연결 실패}. 관리 호스트에서 $MAAS_HOST DNS·방화벽 확인" ;;
    esac
  fi
fi
log "다음: 모델 배포 → MaaSModelRef·MaaSSubscription·MaaSAuthPolicy (manifests/maas/samples) → API key 발급 → 호출 검증(docs/ 버전별 GUIDE)"
