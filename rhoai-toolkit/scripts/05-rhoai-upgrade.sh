#!/usr/bin/env bash
# RHOAI Operator 업그레이드(3.4.x → 3.5.1, 05 작업계획서)
#   하위 명령
#     precheck   조회 전용: 현재 CSV, OCP 버전, 3.5.1 카탈로그·채널, RHCL 버전, 3.5 전환 대상(Llama Stack·MaaS 경로), DSC Ready
#     switch     rhods-operator Subscription의 source·channel을 3.5.1 카탈로그로 변경(Manual 승인 유지, 기본 dry-run)
#     wait       InstallPlan 승인(11-installplan.sh rhods-operator) 후 CSV Succeeded·DSC Ready 대기
#     revert     승인 전에만: Subscription source·channel을 백업 값으로 되돌림(승인 후에는 OLM 다운그레이드 불가 → Red Hat 지원)
#   RHOAI_VERSION은 업그레이드가 끝난 뒤(wait 성공) config/env.sh에서 3.5.1로 바꾼다.
source "$(dirname "$0")/lib/common.sh"
init
CMD=${1:-}
OP_NS=$OPERATOR_NS
SUB=$(find_subscription rhods-operator); [[ -n "$SUB" ]] || die "rhods-operator Subscription이 없습니다."
SUB_NS=${SUB%/*}; SUB_NAME=${SUB#*/}
B=$(backup_dir rhoai351)
cur_csv() { oc get subscriptions.operators.coreos.com "$SUB_NAME" -n "$SUB_NS" -o jsonpath='{.status.installedCSV}'; }

case "$CMD" in
  precheck)
    FAIL=0; bad() { warn "$*"; FAIL=$((FAIL + 1)); }
    step "현재 상태"
    log "Subscription $SUB: $(oc get subscriptions.operators.coreos.com "$SUB_NAME" -n "$SUB_NS" -o jsonpath='{.spec.source}/{.spec.channel} approval={.spec.installPlanApproval}') installed=$(cur_csv)"
    [[ "$(cur_csv)" == rhods-operator.3.4* ]] && ok "현재 3.4.x" || warn "현재 CSV $(cur_csv)"
    [[ "$(oc get subscriptions.operators.coreos.com "$SUB_NAME" -n "$SUB_NS" -o jsonpath='{.spec.installPlanApproval}')" == Manual ]] && ok "Manual 승인" || bad "Automatic 승인 → Manual로 바꾼 뒤 진행"
    OCP=$(oc get clusterversion version -o jsonpath='{.status.desired.version}')
    [[ "$(printf '%s\n%s\n' 4.19.9 "$OCP" | sort -V | head -n1)" == 4.19.9 ]] && ok "OCP $OCP(3.5.1 최소 4.19.9)" || bad "OCP $OCP < 4.19.9"
    [[ "$(oc get datasciencecluster "$DSC_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" == True ]] && ok "DSC Ready" || bad "DSC Ready 아님"
    BAD=$(oc get co --no-headers | awk '$3!="True"||$4!="False"||$5!="False"{print $1}')
    [[ -z "$BAD" ]] && ok "ClusterOperator 정상" || bad "비정상 ClusterOperator: $(echo $BAD)"
    step "3.5.1 카탈로그"
    [[ "${RHOAI351_CATALOG:0:1}" != "<" && -n "$RHOAI351_CATALOG" ]] || die "config/env.sh의 RHOAI351_CATALOG를 지정하세요."
    ST=$(oc get catalogsource "$RHOAI351_CATALOG" -n openshift-marketplace -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || true)
    [[ "$ST" == READY ]] && ok "CatalogSource $RHOAI351_CATALOG READY" || bad "CatalogSource $RHOAI351_CATALOG: ${ST:-없음}"
    HEAD=$(oc get packagemanifests -n openshift-marketplace -l "catalog=$RHOAI351_CATALOG" -o json | jq -r --arg c "$RHOAI351_CHANNEL" '[.items[] | select(.metadata.name=="rhods-operator") | .status.channels[]? | select(.name==$c) | .currentCSV][0] // empty')
    [[ "$HEAD" == "$RHOAI351_CSV" ]] && ok "채널 $RHOAI351_CHANNEL head=$HEAD" || bad "채널 $RHOAI351_CHANNEL head=${HEAD:-없음}(기대 $RHOAI351_CSV)"
    # 반입본에는 3.5.1 하나만 있으므로 3.5.1이 현재 3.4.x를 건너뛰어(skipRange·replaces) 바로 올라갈 수 있어야 한다.
    SKIP=$(oc get packagemanifests -n openshift-marketplace -l "catalog=$RHOAI351_CATALOG" -o json | jq -r --arg c "$RHOAI351_CHANNEL" '[.items[] | select(.metadata.name=="rhods-operator") | .status.channels[]? | select(.name==$c) | .currentCSVDesc.annotations["olm.skipRange"] // empty][0] // empty')
    CURV=$(cur_csv | sed 's/^rhods-operator\.//')
    if [[ -n "$SKIP" ]]; then
      LO=$(sed -n 's/.*>=[[:space:]]*\([0-9][0-9.]*\).*/\1/p' <<<"$SKIP"); HI=$(sed -n 's/.*<[[:space:]]*\([0-9][0-9.]*\).*/\1/p' <<<"$SKIP")
      if [[ -n "$LO" && -n "$HI" && "$(printf '%s\n%s\n' "$LO" "$CURV" | sort -V | head -n1)" == "$LO" && "$(printf '%s\n%s\n' "$CURV" "$HI" | sort -V | head -n1)" == "$CURV" && "$CURV" != "$HI" ]]; then
        ok "skipRange '$SKIP'가 현재 $CURV 포함(한 번에 업그레이드)"
      else
        warn "skipRange '$SKIP'로 $CURV → 3.5.1 경로를 판정하지 못함 → switch 후 InstallPlan에 $RHOAI351_CSV 가 생기는지로 확인(없으면 revert)"
      fi
    else
      warn "skipRange 없음 → switch 후 InstallPlan에 $RHOAI351_CSV 가 생기는지로 확인(없으면 revert)"
    fi
    log "support-required-upgrade-3.5 채널은 2.25→3.5 마이그레이션용이다(3.4→3.5는 $RHOAI351_CHANNEL)."
    step "의존 Operator·3.5 전환 대상"
    RHCL=$(oc get csv -n openshift-operators -o name 2>/dev/null | sed -n 's#.*/rhcl-operator\.v##p' | head -1)
    if [[ -z "$RHCL" ]]; then log "RHCL 미설치(MaaS 미사용이면 무관)"
    elif [[ "$(printf '%s\n%s\n' 1.4.2 "$RHCL" | sort -V | head -n1)" == 1.4.2 ]]; then ok "RHCL $RHCL(1.4.2 이상)"; else bad "RHCL $RHCL < 1.4.2"; fi
    LSD=$( (oc get llamastackdistributions -A --no-headers 2>/dev/null || true) | wc -l)
    ((LSD == 0)) && ok "LlamaStackDistribution 없음" || warn "LlamaStackDistribution ${LSD}개 → 3.5에서 OGXServer로 재생성 필요(백업: $B/llamastackdistributions.yaml)"
    [[ "$(oc get datasciencecluster "$DSC_NAME" -o jsonpath='{.spec.components.kserve.modelsAsService.managementState}' 2>/dev/null)" == Managed ]] \
      && warn "MaaS가 3.4 경로(kserve.modelsAsService)로 켜져 있음 → 업그레이드 후 aigateway로 전환(62-maas.sh, 되돌릴 수 없음)" || true
    [[ "$(oc get datasciencecluster "$DSC_NAME" -o jsonpath='{.spec.components.kueue.managementState}' 2>/dev/null)" == Managed ]] && bad "DSC kueue=Managed(내장) → 3.5 전 RHBoK migration 필요" || true
    oc get installplan -n "$SUB_NS" | awk 'NR==1 || $NF!="true"'
    [[ -s "$B/dsc.yaml" ]] && ok "사전 백업 있음: $B" || bad "사전 백업 없음(01-backup.sh rhoai351)"
    ((FAIL == 0)) && ok "업그레이드 사전 점검 통과" || die "사전 점검 실패 ${FAIL}건"
    ;;

  switch)
    save_once "$B/rhods-subscription.before.json" oc get subscriptions.operators.coreos.com "$SUB_NAME" -n "$SUB_NS" -o json
    [[ -n "$RHOAI351_CATALOG" && "${RHOAI351_CATALOG:0:1}" != "<" ]] || die "config/env.sh의 RHOAI351_CATALOG를 지정하세요."
    confirm "rhods-operator Subscription을 $RHOAI351_CATALOG/$RHOAI351_CHANNEL 로 바꿉니까?(Manual 승인 전까지 설치되지 않음)"
    k_patch subscriptions.operators.coreos.com "$SUB_NAME" "$SUB_NS" merge \
      "{\"spec\":{\"source\":\"$RHOAI351_CATALOG\",\"sourceNamespace\":\"openshift-marketplace\",\"channel\":\"$RHOAI351_CHANNEL\",\"installPlanApproval\":\"Manual\"}}"
    is_dry_run || { sleep 30; oc get installplan -n "$SUB_NS"; log "다음: bash scripts/11-installplan.sh rhods-operator 로 CSV 목록 확인 후 승인"; }
    ;;

  wait)
    DRY_RUN=false   # 조회 전용 대기이므로 dry-run과 관계없이 실제로 기다린다
    wait_for "$RHOAI351_CSV Succeeded" 2400 bash -c "[[ \"\$(oc get csv '$RHOAI351_CSV' -n '$OP_NS' -o jsonpath='{.status.phase}' 2>/dev/null)\" == Succeeded ]]" \
      || die "CSV $RHOAI351_CSV 가 Succeeded가 아닙니다: oc get csv -n $OP_NS; oc get installplan -n $SUB_NS"
    # 3.5 업그레이드 게이트: operator가 확인 항목을 odh-upgrade-acks ConfigMap에 기록한다(스스로 해소한 항목은 지움).
    #   남은 항목은 Release notes·04_검토자료 절차로 확인·승인해야 구성 요소가 갱신된다.
    sleep 60
    if oc get configmap odh-upgrade-acks -n "$OP_NS" >/dev/null 2>&1; then
      warn "업그레이드 게이트(odh-upgrade-acks, $OP_NS) — 남은 항목을 검토 문서 절차로 확인·승인한다:"
      oc get configmap odh-upgrade-acks -n "$OP_NS" -o json | jq -r '.data // {} | to_entries[] | "    \(.key)=\(.value | .[0:80])"'
    else
      ok "업그레이드 게이트 ConfigMap 없음(남은 확인 항목 없음)"
    fi
    # 이전 버전이 남긴 Ready=True에 속지 않도록 DSC가 3.5.1로 갱신됐는지 먼저 확인한다.
    wait_for "DSC release 3.5.1" 1800 bash -c "oc get datasciencecluster '$DSC_NAME' -o jsonpath='{.status.release.version}' | grep -q '^3\.5\.1'" \
      || warn "DSC status.release.version이 3.5.1이 아닙니다: $(oc get datasciencecluster "$DSC_NAME" -o jsonpath='{.status.release.version}') (업그레이드 게이트 확인)"
    wait_for "DSC Ready" 1800 bash -c "[[ \"\$(oc get datasciencecluster '$DSC_NAME' -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}')\" == True ]]" \
      || warn "DSC Ready가 아닙니다(구성 요소 조건 확인)."
    oc get csv -n "$OP_NS"
    oc get datasciencecluster "$DSC_NAME" -o json | jq -r '.status.conditions[] | "  \(.type)=\(.status) \(.message // "" | .[0:100])"'
    oc get pod -n "$AI_NS" --no-headers | grep -vE 'Running|Completed' || ok "$AI_NS 비정상 Pod 없음"
    log "다음: config/env.sh의 RHOAI_VERSION=3.5.1 로 바꾼다."
    ;;

  revert)
    [[ -s "$B/rhods-subscription.before.json" ]] || die "Subscription 백업 없음"
    [[ "$(cur_csv)" == rhods-operator.3.4* ]] || die "이미 $(cur_csv) 설치됨 → Subscription만 되돌릴 수 없습니다(OLM 다운그레이드 불가, Red Hat 지원 요청)."
    P=$(jq -c '{spec:{source:.spec.source, sourceNamespace:.spec.sourceNamespace, channel:.spec.channel, installPlanApproval:.spec.installPlanApproval}}' "$B/rhods-subscription.before.json")
    confirm "Subscription을 백업 값($P)으로 되돌립니까?"
    k_patch subscriptions.operators.coreos.com "$SUB_NAME" "$SUB_NS" merge "$P"
    log "승인하지 않은 InstallPlan은 남아 있어도 설치되지 않는다: oc get installplan -n $SUB_NS"
    ;;
  *) die "사용: $0 precheck|switch|wait|revert" ;;
esac
