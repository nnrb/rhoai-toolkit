#!/usr/bin/env bash
# OdhDashboardConfig 메뉴 활성화 (MaaS 메뉴 제외 — 62-maas.sh에서 처리)
#   - oc apply로 CR 전체를 덮지 않고 merge patch로 필요한 필드만 바꾼다(기존 필드 보존).
#   - 버전별 금지 필드(DASHBOARD_FORBIDDEN)와 스키마에 없는 필드는 건너뛴다.
#   - 이미 같은 값인 필드는 patch에서 뺀다.
#   - STEPWISE=true: 한 필드씩 적용하고 브라우저 확인 후 다음으로 진행(메뉴 회귀 추적용)
# 메뉴 활성화는 화면 노출만 의미한다. 백엔드(인스턴스·이미지)는 각 기능 절차로 구성한다.
source "$(dirname "$0")/lib/common.sh"
init
check_version_match

CUR=$(oc get odhdashboardconfig "$DASH_NAME" -n "$AI_NS" -o json) || die "OdhDashboardConfig/$DASH_NAME 없음"

step "1. 적용 항목 계산 ($VERSION_LABEL)"
collect RAW version_dashboard_items
ITEMS=()
for item in "${RAW[@]}"; do
  key=${item%%=*}
  for f in "${DASHBOARD_FORBIDDEN[@]}"; do
    if [[ "$key" == "$f" ]]; then warn "금지 필드 제외: $key"; continue 2; fi
  done
  # 현재 값과 같으면 제외
  cur=$(jq -c --arg k "$key" '.spec.dashboardConfig[$k]' <<<"$CUR")
  if [[ "$cur" == "$(to_json "${item#*=}")" ]]; then log "이미 설정됨: $key=$cur"; continue; fi
  ITEMS+=("$item")
done
# 이미 CR에 명시된 금지 필드는 알린다(자동 삭제하지 않음).
for f in "${DASHBOARD_FORBIDDEN[@]}"; do
  if jq -e --arg k "$f" '(.spec.dashboardConfig // {}) | has($k)' <<<"$CUR" >/dev/null; then
    warn "금지 필드가 이미 CR에 있습니다: $f — 영향 확인 후 필요하면 수동 제거: oc patch odhdashboardconfig $DASH_NAME -n $AI_NS --type=json -p '[{\"op\":\"remove\",\"path\":\"/spec/dashboardConfig/$f\"}]'"
  fi
done

if ((${#ITEMS[@]} > 0)); then
  mapfile -t ITEMS < <(filter_items odhdashboardconfig "" spec.dashboardConfig "${ITEMS[@]}")
fi
if ((${#ITEMS[@]} == 0)); then ok "변경할 dashboardConfig 필드가 없습니다."; fi
printf '  %s\n' "${ITEMS[@]}"

# Gen AI Studio의 허용 내부 도메인·외부 provider (선택)
GENAI_PATCH='{}'
if is_on "$FEATURE_GENAI" && [[ -n "${GENAI_CLUSTER_DOMAINS:-}" ]]; then
  if has_field odhdashboardconfig spec.genAiStudioConfig.aiAssetCustomEndpoints.clusterDomains; then
    GENAI_PATCH=$(jq -cn --arg d "$GENAI_CLUSTER_DOMAINS" --argjson e "$(to_json "${GENAI_EXTERNAL_PROVIDERS:-false}")" \
      '{spec:{genAiStudioConfig:{aiAssetCustomEndpoints:{clusterDomains:($d|split(",")), externalProviders:$e}}}}')
    log "Gen AI 허용 도메인: $GENAI_CLUSTER_DOMAINS (externalProviders=${GENAI_EXTERNAL_PROVIDERS:-false})"
  else
    warn "spec.genAiStudioConfig 스키마가 없어 허용 도메인 설정을 건너뜁니다."
  fi
fi

step "2. 적용"
backup odhdashboardconfig "$DASH_NAME" "$AI_NS"
if ((${#ITEMS[@]} > 0)) || [[ "$GENAI_PATCH" != '{}' ]]; then
  confirm "OdhDashboardConfig/$DASH_NAME 에 적용합니까?"
fi
if is_on "${STEPWISE:-false}" && ! is_dry_run; then
  for item in "${ITEMS[@]}"; do
    k_patch odhdashboardconfig "$DASH_NAME" "$AI_NS" merge "$(build_patch spec.dashboardConfig "$item")"
    read -r -p "브라우저 새로고침 후 신규 메뉴와 기존 메뉴(MCP 등)를 확인하세요. Enter=계속 / Ctrl+C=중단 " _ </dev/tty
  done
elif ((${#ITEMS[@]} > 0)); then
  k_patch odhdashboardconfig "$DASH_NAME" "$AI_NS" merge "$(build_patch spec.dashboardConfig "${ITEMS[@]}")"
fi
if [[ "$GENAI_PATCH" != '{}' ]]; then
  k_patch odhdashboardconfig "$DASH_NAME" "$AI_NS" merge "$GENAI_PATCH"
fi

step "3. 결과"
oc get odhdashboardconfig "$DASH_NAME" -n "$AI_NS" -o json | jq '.spec.dashboardConfig' | tee "$EVIDENCE_DIR/dashboard.after.json"
# 3.x Dashboard는 data-science-gateway(openshift-ingress) 또는 rhods-dashboard/rh-ai Route로 노출된다.
DASH_HOST=$(oc get route -A -o json 2>/dev/null | jq -r '[.items[] | select(.metadata.name | test("^(data-science-gateway|rh-ai|rhods-dashboard)$")) | .spec.host][0] // "<route 확인: oc get route -A | grep -E \"data-science-gateway|rh-ai|rhods-dashboard\">"' || true)
log "Dashboard 주소: https://${DASH_HOST}"
log "브라우저 강력 새로고침 후 관리자·일반 사용자로 메뉴를 확인하세요. 롤백: scripts/99-rollback.sh dashboard"
