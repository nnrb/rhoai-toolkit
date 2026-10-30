#!/usr/bin/env bash
# llm-d(Distributed inference) 기반: LWS 확인 → GatewayClass → openshift-ai-inference Gateway(ClusterIP+Route)
#   모델 배포(LLMInferenceService)는 Dashboard의 "Distributed inference with llm-d" 또는 manifests/llmd 샘플로 한다.
#   MaaS로 공개할 모델은 maas-default-gateway(62-maas.sh)를 참조하므로 이 Gateway가 없어도 된다.
source "$(dirname "$0")/lib/common.sh"
init envsubst

is_on "$FEATURE_LLMD" || { log "FEATURE_LLMD=false: 건너뜁니다."; exit 0; }

step "1. 전제 조건"
OCP_VER=$(oc get clusterversion version -o jsonpath='{.status.desired.version}')
if [[ "$(printf '%s\n%s\n' 4.20 "$OCP_VER" | sort -V | head -n1)" != "4.20" ]]; then
  die "llm-d는 OpenShift 4.20 이상이 필요합니다(현재 $OCP_VER, RHOAI 3.x 지원 구성표)."
fi
if (oc get csv -A -o name 2>/dev/null || true) | grep 'servicemeshoperator\.v2' >/dev/null; then
  die "Service Mesh v2가 설치되어 있어 llm-d를 구성할 수 없습니다."
fi
csv_succeeded openshift-lws-operator leader-worker-set && ok "LeaderWorkerSet Operator" \
  || warn "LeaderWorkerSet Operator 없음 — 10-operators.sh 먼저 실행 (multi-node·P/D 분리에 필요)"
oc get leaderworkersetoperator cluster >/dev/null 2>&1 && ok "LeaderWorkerSetOperator/cluster" \
  || warn "LeaderWorkerSetOperator/cluster 없음"
has_crd llminferenceservices.serving.kserve.io && ok "LLMInferenceService CRD" \
  || warn "LLMInferenceService CRD 없음 — DSC kserve Managed 상태를 확인하세요."

step "2. GatewayClass"
if GW_CLASS=$(detect_gateway_class); then
  ok "GatewayClass: $GW_CLASS"
else
  apply_template "$TOOLKIT_ROOT/manifests/gateway/gatewayclass.yaml"
  GW_CLASS=openshift-default
fi
wait_for "GatewayClass $GW_CLASS Accepted" 300 gatewayclass_accepted "$GW_CLASS" \
  || warn "Accepted가 아니면 Service Mesh 3 구독(소스 카탈로그)을 확인하세요 — docs/90-troubleshooting.md"

step "3. Gateway $LLMD_GATEWAY_NAME"
if is_on "${LLMD_STANDALONE_GATEWAY:-true}"; then
  GW_NAME=$LLMD_GATEWAY_NAME
  GW_HOST=${LLMD_HOSTNAME:-inference-gateway.$(apps_domain)}
  GW_TLS_SECRET=$LLMD_TLS_SECRET
  GW_ANNOTATIONS='{}'
  export GW_NAME GW_CLASS GW_HOST GW_TLS_SECRET GW_ANNOTATIONS GATEWAY_ACCESS_LABEL
  ensure_tls_secret "$GW_TLS_SECRET" openshift-ingress "${LLMD_TLS_CERT_FILE:-}" "${LLMD_TLS_KEY_FILE:-}"
  if oc get gateway "$GW_NAME" -n openshift-ingress >/dev/null 2>&1; then
    ok "Gateway/$GW_NAME 이미 존재 — 변경하지 않습니다."
  else
    apply_template "$TOOLKIT_ROOT/manifests/gateway/gateway-clusterip.yaml" "$GW_NAME"
  fi
  wait_for "Gateway $GW_NAME Programmed" 300 \
    oc wait --for=condition=Programmed "gateway/$GW_NAME" -n openshift-ingress --timeout=10s || true
else
  log "LLMD_STANDALONE_GATEWAY=false: 별도 Gateway를 만들지 않습니다."
fi

step "4. 모델 namespace 허용"
sync_gateway_access_label "$LLMD_GATEWAY_NAME"
label_model_namespaces

step "5. 확인"
oc get gatewayclass,gateway -A 2>/dev/null || true
log "샘플: manifests/llmd/llminferenceservice-sample.yaml (이미지·모델 경로를 내부 값으로 바꾼 뒤 사용)"
