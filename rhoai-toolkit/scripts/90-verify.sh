#!/usr/bin/env bash
# 상태 점검(조회 전용). 재부팅 후 점검에도 사용한다.
#   메뉴 표시 ≠ 기능 동작. 여기서는 백엔드 리소스 상태까지 확인하고, 실제 사용자 시나리오는 GUIDE의 검증표로 확인한다.
source "$(dirname "$0")/lib/common.sh"
export DRY_RUN=true
init
# 출력 전체를 증적으로 남긴다.
exec > >(tee "$EVIDENCE_DIR/90-verify.txt") 2>&1
log "증적: $EVIDENCE_DIR/90-verify.txt"

row() { printf '  %-34s %s\n' "$1" "$2"; }
status_of() { "$@" >/dev/null 2>&1 && echo "OK" || echo "확인 필요"; }

step "DSC condition"
oc get datasciencecluster "$DSC_NAME" -o json 2>/dev/null \
  | jq -r '.status.conditions[]? | "  \(.type)=\(.status) \(if .status == "False" then (.message // "" | .[0:120]) else "" end)"' \
  || warn "DSC/$DSC_NAME 조회 실패"

step "Dashboard 플래그"
oc get odhdashboardconfig "$DASH_NAME" -n "$AI_NS" -o json 2>/dev/null | jq -c '.spec.dashboardConfig' \
  || warn "OdhDashboardConfig/$DASH_NAME 조회 실패"

# cnt <리소스> [인자..]: 개수(CRD가 없으면 0). jp <기본값> <oc get 인자..>: 조회 실패 시 기본값
cnt() { (oc get "$@" --no-headers 2>/dev/null || true) | wc -l; }
jp()  { local d=$1; shift; oc get "$@" 2>/dev/null || echo "$d"; }

step "기능별 백엔드"
row "Kueue ClusterQueue/$KUEUE_QUEUE_NAME" "$(status_of oc get clusterqueue "$KUEUE_QUEUE_NAME")"
row "HardwareProfile 수" "$(cnt hardwareprofiles.infrastructure.opendatahub.io -n "$AI_NS")"
row "LeaderWorkerSetOperator" "$(status_of oc get leaderworkersetoperator cluster)"
row "Gateway $LLMD_GATEWAY_NAME" "$(oc get gateway "$LLMD_GATEWAY_NAME" -n openshift-ingress -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo 없음)"
row "Gateway maas-default-gateway" "$(oc get gateway maas-default-gateway -n openshift-ingress -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo 없음)"
row "Kuadrant Ready" "$(oc get kuadrant kuadrant -n kuadrant-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo 없음)"
row "Authorino CR" "$(oc get authorinos.operator.authorino.kuadrant.io -A --no-headers 2>/dev/null | awk '{print $1"/"$2}' | xargs || true)"
row "Authorino tokenreviews 권한" "$(oc auth can-i create tokenreviews.authentication.k8s.io --as=system:serviceaccount:kuadrant-system:authorino-authorino 2>/dev/null || true)"
# maas-api는 3.4(redhat-ods-applications)와 3.5(infra namespace)에 함께 있을 수 있어 모두 표시한다.
for ns in $( (oc get deploy -A -o json 2>/dev/null || echo '{"items":[]}') | jq -r '.items[] | select(.metadata.name == "maas-api") | .metadata.namespace'); do
  row "maas-api ($ns)" "$(jp '?' deploy maas-api -n "$ns" -o jsonpath='{.status.readyReplicas}/{.spec.replicas}')"
done
row "maas-postgresql" "$(jp 없음 deploy maas-postgresql -n "$MAAS_DB_NS" -o jsonpath='{.status.readyReplicas}/{.spec.replicas}')"
row "ModelRegistry" "$(cnt modelregistries.modelregistry.opendatahub.io -A)개"
row "LlamaStackDistribution" "$(cnt llamastackdistributions -A)개"
row "MonitoringStack(DSCI)" "$(cnt monitoringstacks.monitoring.rhobs -A)개"
row "UIPlugin" "$( (oc get uiplugin -o name 2>/dev/null || true) | xargs)"
row "accelerator recording rule" "$( (oc get prometheusrule -A --no-headers 2>/dev/null || true) | grep -c accelerator-recording-rules || true)개"
row "Tenant gatewayRef" "$(jp 해당없음 tenants.maas.opendatahub.io default-tenant -n models-as-a-service -o jsonpath='{.spec.gatewayRef.name}')"
row "Limitador storage" "$( (oc get limitador limitador -n kuadrant-system -o jsonpath='{.spec.storage}' 2>/dev/null || true) | jq -c 'keys' 2>/dev/null || echo 없음)"
row "MaaS EnvoyFilter" "$( (oc get envoyfilter -n openshift-ingress -o name 2>/dev/null || true) | grep -cE 'healthcheck-filter|increase-ratelimit' || true)/2"
row "MLflow" "$(cnt mlflows.mlflow.opendatahub.io -A)개"
row "EvalHub" "$(cnt evalhubs.trustyai.opendatahub.io -A)개"
row "Kubernetes MCP 서버" "$(jp 없음 deploy kubernetes-mcp-server -n "$MCP_NS" -o jsonpath='{.status.readyReplicas}/{.spec.replicas}')"

step "OpenTelemetry·검증 모델(04 작업계획서)"
row "TempoStack $TEMPO_NS/$TEMPO_STACK Ready" "$(jp 없음 tempostack "$TEMPO_STACK" -n "$TEMPO_NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
row "Collector $PROD_NS/llm-otel-collector" "$(jp 없음 deploy llm-otel-collector -n "$PROD_NS" -o jsonpath='{.status.readyReplicas}/{.spec.replicas}')"
row "Instrumentation($PROD_NS)" "$( (oc get instrumentation -n "$PROD_NS" -o name 2>/dev/null || true) | xargs)"
row "OTel 주입 모델($PROD_NS)" "$( (oc get isvc,llmisvc -n "$PROD_NS" -o json 2>/dev/null || echo '{"items":[]}') | jq -r '[.items[] | select(((.spec.predictor.annotations // .spec.annotations // {})["instrumentation.opentelemetry.io/inject-python"] // "false") != "false") | .metadata.name] | join(" ")')"
row "검증 LLMI $MODEL_NS/${MODEL_NAME:-?} Ready" "$(jp 없음 llminferenceservice "${MODEL_NAME:-none}" -n "$MODEL_NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"

step "Gateway Wasm 로드 (재부팅 후 Dashboard 504 점검, TS-20)"
for g in data-science-gateway maas-default-gateway; do
  P=$(oc get pod -n openshift-ingress -l "gateway.networking.k8s.io/gateway-name=$g" -o name 2>/dev/null | head -n1 || true)
  [[ -n "$P" ]] || continue
  S=$(oc exec -n openshift-ingress "$P" -- pilot-agent request GET stats 2>/dev/null \
      | grep -E '^wasm\.remote_load_fetch_(failures|successes)' | tr '\n' ' ' || true)
  row "$g" "${S:-통계 없음}"
done
log "fetch_failures>0 이고 successes=0 이면: oc delete pod -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=<gateway>"

step "실패 Pod"
oc get pods -A --no-headers 2>/dev/null \
  | grep -E "redhat-ods|redhat-ai-gateway|rhoai|kuadrant|openshift-ingress|kueue|lws|models-as-a-service|${MCP_NS}|${PROD_NS}|${MODEL_NS}|${TEMPO_NS}" \
  | grep -vE 'Running|Completed' || ok "비정상 Pod 없음"
