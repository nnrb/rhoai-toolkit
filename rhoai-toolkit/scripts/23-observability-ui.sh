#!/usr/bin/env bash
# 관측 화면(RHOAI-Toolkit setup_observability_uiplugins·ensure_accelerator_metrics를 폐쇄망용으로 옮김)
#   1) COO UIPlugin dashboards·monitoring(Perses) — 없을 때만 만든다(있으면 변경하지 않음)
#   2) GPU accelerator_* recording rule — DCGM 메트릭을 RHOAI Observe 대시보드 이름으로 바꾼다(없으면 GPU 패널 No data)
#   추가 이미지 없음(COO·GPU Operator 이미지 사용). 선행: 21-observability.sh
source "$(dirname "$0")/lib/common.sh"
init

is_on "$FEATURE_OBSERVABILITY" && is_on "$FEATURE_OBS_UI" || { log "FEATURE_OBS_UI=false: 건너뜁니다."; exit 0; }

step "1. COO UIPlugin"
if ! has_crd uiplugins.observability.openshift.io; then
  warn "UIPlugin CRD 없음(COO 미설치) — 건너뜁니다."
else
  COO_VER=$(oc get csv -A -o json | jq -r '[.items[] | select(.metadata.name | startswith("cluster-observability-operator.")) | .spec.version][0] // empty')
  log "COO 버전: ${COO_VER:-확인 불가}"
  [[ "$COO_VER" == 1.5.0 ]] && warn "COO 1.5.0은 Perses 기동 오류 보고가 있다(-web.tls-min-version). 증상 시 docs/90-troubleshooting.md"
  for p in dashboards monitoring; do
    if oc get uiplugin "$p" >/dev/null 2>&1; then
      ok "UIPlugin/$p 이미 있음 — 변경하지 않습니다($(oc get uiplugin "$p" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}'))"
      continue
    fi
    f="$EVIDENCE_DIR/uiplugin-$p.yaml"
    if [[ "$p" == dashboards ]]; then
      printf 'apiVersion: observability.openshift.io/v1alpha1\nkind: UIPlugin\nmetadata:\n  name: dashboards\nspec:\n  type: Dashboards\n' >"$f"
    else
      printf 'apiVersion: observability.openshift.io/v1alpha1\nkind: UIPlugin\nmetadata:\n  name: monitoring\nspec:\n  type: Monitoring\n  monitoring:\n    perses:\n      enabled: true\n' >"$f"
    fi
    confirm "UIPlugin/$p를 만듭니까?"
    k_apply "$f"
  done
fi

step "2. GPU accelerator_* recording rule"
GPU_NS=$(oc get clusterpolicy -o jsonpath='{.items[0].status.namespace}' 2>/dev/null || true)
GPU_NS=${GPU_NS:-nvidia-gpu-operator}
if ! oc get ns "$GPU_NS" >/dev/null 2>&1; then
  warn "GPU Operator namespace($GPU_NS) 없음 — 건너뜁니다."
elif oc get prometheusrule accelerator-recording-rules -n "$GPU_NS" >/dev/null 2>&1; then
  ok "PrometheusRule accelerator-recording-rules 이미 있음"
else
  oc get servicemonitor -n "$GPU_NS" 2>/dev/null | grep -q dcgm || warn "DCGM exporter ServiceMonitor가 보이지 않습니다. GPU 메트릭 수집 여부를 확인하세요."
  f="$EVIDENCE_DIR/accelerator-recording-rules.yaml"
  {
    printf 'apiVersion: monitoring.coreos.com/v1\nkind: PrometheusRule\nmetadata:\n  name: accelerator-recording-rules\n  namespace: %s\n  labels:\n    app: nvidia-gpu-operator\nspec:\n  groups:\n  - name: accelerator.rules\n    interval: 30s\n    rules:\n' "$GPU_NS"
    while read -r rec expr; do
      printf '    - record: %s\n      expr: label_replace(%s, "k8s_pod_name", "$1", "exported_pod", "(.*)")\n' "$rec" "$expr"
    done <<'RULES'
accelerator_gpu_utilization DCGM_FI_DEV_GPU_UTIL
accelerator_memory_used_bytes DCGM_FI_DEV_FB_USED*1024*1024
accelerator_memory_total_bytes (DCGM_FI_DEV_FB_USED+DCGM_FI_DEV_FB_FREE)*1024*1024
accelerator_memory_clock_hertz DCGM_FI_DEV_MEM_CLOCK*1e6
accelerator_sm_clock_hertz DCGM_FI_DEV_SM_CLOCK*1e6
accelerator_power_usage_watts DCGM_FI_DEV_POWER_USAGE
accelerator_temperature_celsius DCGM_FI_DEV_GPU_TEMP
RULES
  } >"$f"
  confirm "PrometheusRule accelerator-recording-rules($GPU_NS)를 만듭니까?"
  k_apply "$f"
fi
log "확인: oc get uiplugin; 콘솔 Observe > Dashboards, RHOAI Dashboard > Observe & monitor"
