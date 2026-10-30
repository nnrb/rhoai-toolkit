#!/usr/bin/env bash
# 사전 점검(조회 전용). 클러스터를 변경하지 않는다.
#   버전 일치, 미러 카탈로그·IDMS, DSC/DSCI 상태, 의존 오퍼레이터, 알려진 충돌 조건을 확인하고
#   현재 상태를 EVIDENCE_DIR에 저장한다.
source "$(dirname "$0")/lib/common.sh"
init

FAIL=0
fail() { warn "$*"; FAIL=$((FAIL + 1)); }

step "1. 클러스터·RHOAI 버전"
OCP_VER=$(oc get clusterversion version -o jsonpath='{.status.desired.version}')
if [[ "$(printf '%s\n%s\n' "$OCP_MIN_VERSION" "$OCP_VER" | sort -V | head -n1)" == "$OCP_MIN_VERSION" ]]; then
  ok "OpenShift $OCP_VER (최소 $OCP_MIN_VERSION)"
else
  fail "OpenShift $OCP_VER 은 $VERSION_LABEL 최소 버전 $OCP_MIN_VERSION 미만입니다."
fi
check_version_match
if is_on "$FEATURE_LLMD" && [[ "$(printf '%s\n%s\n' 4.20 "$OCP_VER" | sort -V | head -n1)" != "4.20" ]]; then
  fail "llm-d는 OpenShift 4.20 이상이 필요합니다. FEATURE_LLMD=false 로 두거나 OCP를 올리세요."
fi
if uwm_enabled; then ok "User Workload Monitoring 켜짐"; else warn "User Workload Monitoring 꺼짐 — MaaS·모델 메트릭에 필요(21-observability.sh)"; fi

step "2. 폐쇄망 카탈로그·미러"
if [[ "$(oc get operatorhub cluster -o jsonpath='{.spec.disableAllDefaultSources}')" == "true" ]]; then
  ok "기본 온라인 CatalogSource 비활성화됨"
else
  warn "OperatorHub 기본 CatalogSource가 켜져 있습니다. 폐쇄망에서는 끄는 것을 권장합니다(docs/01-airgap-mirroring.md)."
fi
CATALOGS=("$CATALOG_SOURCE")
if is_on "$FEATURE_GPU"; then CATALOGS+=("$CERTIFIED_CATALOG_SOURCE"); fi
for cs in "${CATALOGS[@]}"; do
  state=$(oc get catalogsource "$cs" -n openshift-marketplace -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || true)
  if [[ "$state" == "READY" ]]; then ok "CatalogSource $cs READY"; else fail "CatalogSource $cs 상태: ${state:-없음}"; fi
done
IDMS=$( (oc get imagedigestmirrorset -o name 2>/dev/null || true) | wc -l)
ITMS=$( (oc get imagetagmirrorset -o name 2>/dev/null || true) | wc -l)
if (( IDMS > 0 )); then ok "IDMS ${IDMS}개, ITMS ${ITMS}개"; else fail "IDMS가 없습니다. oc-mirror 결과(cluster-resources)를 적용하세요."; fi

step "3. DSC / DSCI / Dashboard"
oc get datasciencecluster "$DSC_NAME" >/dev/null 2>&1 || fail "DataScienceCluster/$DSC_NAME 없음"
oc get dscinitialization "$DSCI_NAME" >/dev/null 2>&1 || fail "DSCInitialization/$DSCI_NAME 없음"
oc get odhdashboardconfig "$DASH_NAME" -n "$AI_NS" >/dev/null 2>&1 || fail "OdhDashboardConfig/$DASH_NAME 없음"
log "DSC condition (False인 항목):"
oc get datasciencecluster "$DSC_NAME" -o json 2>/dev/null \
  | jq -r '.status.conditions[]? | select(.status == "False") | "  - \(.type): \(.reason // "") \(.message // "" | .[0:160])"' || true
log "DSC components 현재 상태:"
oc get datasciencecluster "$DSC_NAME" -o json 2>/dev/null \
  | jq -r '.spec.components | to_entries[] | "  \(.key): \(.value.managementState // "-")"' || true

step "4. 의존 오퍼레이터 (설치된 CSV)"
oc get csv -A -o json | jq -r '
  [.items[] | select(.metadata.name | test("cert-manager|leader-worker-set|rhcl|authorino|limitador|kueue|job-set|jobset|servicemesh|cluster-observability|opentelemetry|tempo|nfd|gpu-operator"))
   | "\(.metadata.name)\t\(.status.phase)"] | unique[] | "  " + .'

step "5. 알려진 충돌 조건"
# llm-d는 Service Mesh v2와 공존할 수 없다.
if (oc get csv -A -o name 2>/dev/null || true) | grep 'servicemeshoperator\.v2' >/dev/null; then
  fail "Service Mesh v2(servicemeshoperator)가 설치되어 있습니다. llm-d 전제 조건 위반입니다."
else
  ok "Service Mesh v2 없음"
fi
# OCP의 Gateway API가 Service Mesh 3를 직접 관리한다. 수동 구독은 GatewayClass를 Accepted: Unknown으로 만들 수 있다.
OSSM3=$(find_subscription servicemeshoperator3)
if [[ -n "$OSSM3" ]]; then
  log "servicemeshoperator3 구독: $OSSM3 (source: $(oc get sub -n "${OSSM3%/*}" "${OSSM3#*/}" -o jsonpath='{.spec.source}'))"
fi
# Authorino CR 이름 중복 → ClusterRoleBinding 공유 → 재부팅 후 MaaS 401 (TS-19)
AUTHORINOS=$(oc get authorinos.operator.authorino.kuadrant.io -A -o json 2>/dev/null \
  | jq -r '[.items[] | "\(.metadata.namespace)/\(.metadata.name)"] | join(" ")' || true)
# 60-rhcl.sh와 같은 기준: kuadrant-system 외 Authorino CR은 MaaS 구성 전에 사용처를 정한다(04 작업계획서 5단계 12-rhcl-deps.sh precheck가 차단).
OTHER_AUTHORINOS=$(tr ' ' '\n' <<<"$AUTHORINOS" | grep -v '^kuadrant-system/' | xargs || true)
if [[ -n "$OTHER_AUTHORINOS" ]] && ! is_on "${AUTHORINO_DUP_ACK:-false}"; then
  warn "kuadrant-system 외 Authorino CR: $OTHER_AUTHORINOS — MaaS 구성 전에 사용처 확인 후 정리하거나 AUTHORINO_DUP_ACK=true(이름이 authorino면 RBAC 충돌, docs/90-troubleshooting.md TS-19)."
elif [[ -n "$OTHER_AUTHORINOS" ]]; then
  warn "kuadrant-system 외 Authorino CR 유지(AUTHORINO_DUP_ACK=true): $OTHER_AUTHORINOS"
else
  ok "Authorino CR: ${AUTHORINOS:-없음}"
fi
# 내장 Kueue가 Managed이면 Red Hat build of Kueue로 migration이 먼저 필요하다.
if [[ "$(oc get datasciencecluster "$DSC_NAME" -o jsonpath='{.spec.components.kueue.managementState}' 2>/dev/null)" == "Managed" ]]; then
  warn "DSC kueue가 Managed(내장)입니다. FEATURE_KUEUE=true면 공식 migration 절차 후 Unmanaged로 전환합니다."
fi

step "6. GPU·스토리지"
GPU_NODES=$(oc get nodes -o json | jq --arg r "$GPU_RESOURCE_NAME" '[.items[] | select((.status.allocatable[$r] // "0") != "0")] | length')
log "GPU 노드($GPU_RESOURCE_NAME): ${GPU_NODES}대"
if [[ -n "$STORAGE_CLASS" ]]; then
  oc get storageclass "$STORAGE_CLASS" >/dev/null 2>&1 && ok "StorageClass $STORAGE_CLASS" || fail "StorageClass $STORAGE_CLASS 없음"
else
  log "기본 StorageClass: $(oc get sc -o json | jq -r '[.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true") | .metadata.name] | join(",")')"
fi

step "7. 현재 상태 저장"
oc get datasciencecluster "$DSC_NAME" -o yaml >"$EVIDENCE_DIR/dsc.before.yaml" 2>/dev/null || true
oc get dscinitialization "$DSCI_NAME" -o yaml >"$EVIDENCE_DIR/dsci.before.yaml" 2>/dev/null || true
oc get odhdashboardconfig "$DASH_NAME" -n "$AI_NS" -o yaml >"$EVIDENCE_DIR/dashboard.before.yaml" 2>/dev/null || true
oc get csv -A >"$EVIDENCE_DIR/csv.txt" 2>/dev/null || true
oc explain datasciencecluster.spec.components --recursive --api-version="$DSC_API" >"$EVIDENCE_DIR/explain-dsc.txt" 2>/dev/null || true
oc explain odhdashboardconfig.spec --recursive >"$EVIDENCE_DIR/explain-dashboard.txt" 2>/dev/null || true
ok "저장 위치: $EVIDENCE_DIR"

version_prechecks

echo
if (( FAIL > 0 )); then die "사전 점검 실패 ${FAIL}건. 위 경고를 해결한 뒤 진행하세요."; fi
ok "사전 점검 통과"
