#!/usr/bin/env bash
# 승인 대기 InstallPlan 확인·승인(Manual 승인 Subscription)
#   사용: bash scripts/11-installplan.sh <패키지> [기대 CSV]          (조회: 설치·변경될 CSV 목록)
#         DRY_RUN=false bash scripts/11-installplan.sh <패키지> [기대 CSV]   (확인 질문 후 승인)
#   기대 CSV를 주면 그 CSV가 든 계획만 다룬다(이미 설치됐으면 OK로 끝냄, 이전 계획이면 중단).
#   같은 namespace의 InstallPlan은 여러 Operator의 CSV를 함께 담는다. 목록에 계획 외 CSV가 있으면 승인하지 않는다.
#   예: rhcl-operator 승인 목록에 authorino-operator가 보이면 12-rhcl-deps.sh 단계가 끝나지 않은 것이다.
source "$(dirname "$0")/lib/common.sh"
init
PKG=${1:-}; EXPECT=${2:-}
[[ -n "$PKG" ]] || die "사용: $0 <패키지 이름(rhcl-operator, leader-worker-set, rhods-operator 등)> [기대 CSV]"
SUB=$(find_subscription "$PKG")
[[ -n "$SUB" ]] || die "$PKG Subscription이 없습니다."
NS=${SUB%/*}; NAME=${SUB#*/}

step "Subscription $SUB"
oc get subscriptions.operators.coreos.com "$NAME" -n "$NS" \
  -o jsonpath='{"channel="}{.spec.channel}{"  source="}{.spec.source}{"  approval="}{.spec.installPlanApproval}{"  startingCSV="}{.spec.startingCSV}{"  installed="}{.status.installedCSV}{"  current="}{.status.currentCSV}{"\n"}'
INST=$(oc get subscriptions.operators.coreos.com "$NAME" -n "$NS" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
if [[ -n "$EXPECT" && "$INST" == "$EXPECT" ]]; then ok "이미 설치됨: $EXPECT"; exit 0; fi
IP=$(oc get subscriptions.operators.coreos.com "$NAME" -n "$NS" -o jsonpath='{.status.installPlanRef.name}' 2>/dev/null || true)
[[ -n "$IP" ]] || { warn "InstallPlan이 아직 없습니다. 잠시 후 다시 실행하세요(카탈로그 상태 확인)."; exit 0; }
oc get installplan "$IP" -n "$NS" >/dev/null 2>&1 || die "InstallPlan $IP 를 찾을 수 없습니다(정리됨). 잠시 후 다시 실행하세요."
# 이전에 승인된 계획을 보고 끝내지 않도록, 기대 CSV(인자)가 이 계획에 들어 있는지 확인한다.
CSVS=$(oc get installplan "$IP" -n "$NS" -o jsonpath='{.spec.clusterServiceVersionNames[*]}')
if [[ -n "$EXPECT" && " $CSVS " != *" $EXPECT "* ]]; then
  die "InstallPlan $IP 에 $EXPECT 가 없습니다(현재 계획: $CSVS) → 이전 계획이거나 아직 해석 전입니다. 구독 상태를 확인하고 다시 실행하세요."
fi

step "InstallPlan $NS/$IP"
APPROVED=$(oc get installplan "$IP" -n "$NS" -o jsonpath='{.spec.approved}')
log "approved=$APPROVED  phase=$(oc get installplan "$IP" -n "$NS" -o jsonpath='{.status.phase}')"
log "설치·변경될 CSV:"
oc get installplan "$IP" -n "$NS" -o jsonpath='{range .spec.clusterServiceVersionNames[*]}{"  - "}{@}{"\n"}{end}'
log "현재 설치된 CSV(같은 namespace):"
oc get csv -n "$NS" -o custom-columns=NAME:.metadata.name,PHASE:.status.phase --no-headers | sed 's/^/  /'
if [[ "$APPROVED" == "true" ]]; then ok "이미 승인됨"; exit 0; fi
if is_dry_run; then log "DRY_RUN=true: 승인하지 않습니다. 목록 확인 후 DRY_RUN=false로 다시 실행하세요."; exit 0; fi
confirm "위 CSV 목록으로 InstallPlan $IP 를 승인합니까?"
oc patch installplan "$IP" -n "$NS" --type=merge -p '{"spec":{"approved":true}}'
if [[ "$PKG" == rhods-operator ]]; then
  log "RHOAI 업그레이드 완료 대기는 05-rhoai-upgrade.sh wait 로 확인한다(이전 CSV가 남아 있어 여기서는 판단하지 않음)."
else
  for c in $(oc get installplan "$IP" -n "$NS" -o jsonpath='{.spec.clusterServiceVersionNames[*]}'); do
    wait_for "$c Succeeded" 900 bash -c "[[ \"\$(oc get csv '$c' -n '$NS' -o jsonpath='{.status.phase}' 2>/dev/null)\" == Succeeded ]]" || warn "$c 가 Succeeded가 아닙니다: oc get csv -n $NS"
  done
fi
oc get csv -n "$NS" -o custom-columns=NAME:.metadata.name,PHASE:.status.phase --no-headers | sed 's/^/  /'
