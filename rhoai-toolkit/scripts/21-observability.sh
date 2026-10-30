#!/usr/bin/env bash
# 관측 기반: User Workload Monitoring + DSCI spec.monitoring(metrics/traces)
#   모델 메트릭·Endpoint Performance·통합 관측 대시보드(observabilityDashboard)의 백엔드다.
#   선행: 10-operators.sh 의 COO·OpenTelemetry·Tempo (FEATURE_OBSERVABILITY=true)
source "$(dirname "$0")/lib/common.sh"
init

is_on "$FEATURE_OBSERVABILITY" || { log "FEATURE_OBSERVABILITY=false: 건너뜁니다."; exit 0; }

step "1. User Workload Monitoring"
CMO_CFG=$(oc get configmap cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null || true)
if grep -Eq '^enableUserWorkload:[[:space:]]*true' <<<"$CMO_CFG"; then
  ok "enableUserWorkload: true"
elif [[ -n "$CMO_CFG" ]]; then
  # 기존 설정(보존 기간·저장소 등)을 덮어쓰지 않기 위해 자동 수정하지 않는다.
  warn "cluster-monitoring-config가 이미 있습니다. config.yaml 최상위에 'enableUserWorkload: true'를 직접 추가하세요:"
  warn "  oc edit configmap cluster-monitoring-config -n openshift-monitoring"
else
  cat >"$EVIDENCE_DIR/cluster-monitoring-config.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF
  k_apply "$EVIDENCE_DIR/cluster-monitoring-config.yaml"
fi

step "2. DSCI monitoring"
for crd in monitoringstacks.monitoring.rhobs opentelemetrycollectors.opentelemetry.io tempostacks.tempo.grafana.com; do
  if has_crd "$crd"; then ok "CRD $crd"; else warn "CRD $crd 없음 — 해당 오퍼레이터 설치 후 다시 실행하세요."; fi
done

ITEMS=(
  "managementState=Managed"
  "alerting={}"
  "metrics.replicas=1"
  "metrics.storage.size=${METRICS_STORAGE_SIZE}"
  "metrics.storage.retention=${METRICS_RETENTION}"
)
# namespace는 최초 1회만 지정한다(이미 값이 있으면 유지).
if [[ -z "$(oc get dscinitialization "$DSCI_NAME" -o jsonpath='{.spec.monitoring.namespace}' 2>/dev/null)" ]]; then
  ITEMS+=("namespace=${MONITORING_NS}")
fi
if has_crd tempostacks.tempo.grafana.com; then
  ITEMS+=(
    "traces.sampleRatio=\"${TRACES_SAMPLE_RATIO}\""
    "traces.storage.backend=${TRACES_BACKEND}"
    "traces.storage.retention=${TRACES_RETENTION}"
  )
  if [[ "$TRACES_BACKEND" == "s3" ]]; then
    [[ -n "${TRACES_S3_SECRET:-}" ]] || die "TRACES_BACKEND=s3 이면 TRACES_S3_SECRET(버킷 접속 Secret 이름)이 필요합니다."
    ITEMS+=("traces.storage.secret=${TRACES_S3_SECRET}")
  fi
fi

mapfile -t ITEMS < <(filter_items dscinitialization "" spec.monitoring "${ITEMS[@]}")
PATCH=$(build_patch spec.monitoring "${ITEMS[@]}")
backup dscinitialization "$DSCI_NAME"
confirm "DSCInitialization/$DSCI_NAME monitoring을 변경합니까?"
k_patch dscinitialization "$DSCI_NAME" "" merge "$PATCH"

step "3. 확인"
log "확인 명령: oc get pods -n ${MONITORING_NS}; oc get monitoringstack,tempostack,opentelemetrycollector -n ${MONITORING_NS}"
log "사용자 워크로드 수집: 메트릭을 노출하는 namespace/워크로드에 monitoring.opendatahub.io/scrape=true 라벨"
