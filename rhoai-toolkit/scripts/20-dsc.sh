#!/usr/bin/env bash
# DataScienceCluster 컴포넌트를 FEATURE_* 선택에 맞춰 Managed로 전환한다.
#   - MaaS(kserve.modelsAsService / aigateway)는 인프라 준비 후 62-maas.sh가 켠다.
#   - 설치된 스키마에 없는 필드는 건너뛴다.
#   - 운영 데이터에 영향을 주는 전환은 *_ACK=true가 없으면 건너뛴다.
source "$(dirname "$0")/lib/common.sh"
init
check_version_match

# drop_items <접두어>  : ITEMS 배열에서 접두어로 시작하는 항목 제거
drop_items() {
  local prefix=$1 i; local -a kept=()
  for i in "${ITEMS[@]}"; do [[ "$i" == "$prefix"* ]] || kept+=("$i"); done
  ITEMS=("${kept[@]}")
}

step "1. 적용 항목 계산 ($VERSION_LABEL)"
collect ITEMS version_dsc_items

CUR_KUEUE=$(oc get datasciencecluster "$DSC_NAME" -o jsonpath='{.spec.components.kueue.managementState}' 2>/dev/null || true)
if is_on "$FEATURE_KUEUE" && [[ "$CUR_KUEUE" == "Managed" ]] && ! is_on "${KUEUE_MIGRATION_ACK:-false}"; then
  warn "내장 Kueue(Managed) 사용 중입니다. 공식 migration 절차를 마친 뒤 KUEUE_MIGRATION_ACK=true로 다시 실행하세요. kueue 항목을 건너뜁니다."
  drop_items "kueue."
fi

if is_on "$FEATURE_TRAINER" && ! has_crd jobsets.jobset.x-k8s.io; then
  warn "JobSet CRD(jobsets.jobset.x-k8s.io)가 없습니다. trainer 항목을 건너뜁니다(10-operators.sh 먼저 실행)."
  drop_items "trainer."
fi
if is_on "$FEATURE_TRAINER" && is_on "$FEATURE_KUEUE"; then
  KUEUE_CSV=$( (oc get csv -A -o name 2>/dev/null || true) | sed -n 's#.*/\(kueue-operator\.v[0-9.]*\)$#\1#p' | head -n1)
  if [[ "$KUEUE_CSV" =~ kueue-operator\.v1\.([4-9]|[1-9][0-9]) ]]; then
    warn "$KUEUE_CSV: Kubeflow Trainer는 RHBoK 1.4 이상과 호환되지 않습니다(RHOAIENG-87965). 1.3 채널을 사용하세요."
  fi
fi

# 버전별 안전장치 (3.5.1: Llama Stack → OGX 전환 확인 등)
version_dsc_guard

mapfile -t ITEMS < <(filter_items datasciencecluster "$DSC_API" spec.components "${ITEMS[@]}")
((${#ITEMS[@]} > 0)) || die "적용할 항목이 없습니다."
printf '  %s\n' "${ITEMS[@]}"

PATCH=$(build_patch spec.components "${ITEMS[@]}")
printf '%s\n' "$PATCH" | jq . >"$EVIDENCE_DIR/dsc.patch.json"

step "2. 적용"
backup datasciencecluster "$DSC_NAME"
confirm "DataScienceCluster/$DSC_NAME 에 위 항목을 적용합니까?"
k_patch datasciencecluster "$DSC_NAME" "" merge "$PATCH"

step "3. 상태 확인"
dsc_ready() { [[ "$(dsc_condition Ready)" == "True" ]]; }
# patch 직후에는 이전 Ready=True가 남아 있으므로 operator reconcile을 기다린 뒤 판정한다.
is_dry_run || sleep 60
wait_for "DSC Ready" 900 dsc_ready || warn "DSC가 Ready가 아닙니다. 아래 False condition을 확인하세요."
oc get datasciencecluster "$DSC_NAME" -o json \
  | jq -r '.status.conditions[]? | "  \(.type): \(.status) \(.reason // "")"' || true
