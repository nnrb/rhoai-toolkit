#!/usr/bin/env bash
# RHCL 의존 Operator(authorino·limitador·dns) 구독을 RHCL 카탈로그(CATALOG_SOURCE)로 맞춘다(04 작업계획서, RHCL 구독 전).
#   배경(2026-10-30 확인): authorino-operator v1.2.2 구독은 cs-redhat-operator-index(1.2.2만 있음)를 보고, v1.4.2는 ai-other에만 있다.
#   OLM은 기존 구독을 그 구독의 카탈로그에서만 업그레이드하므로, 그대로 RHCL 1.4.2를 구독하면 의존성 해석이 실패할 수 있다.
#   하위 명령
#     precheck  조회 전용: 카탈로그 head·skipRange, 기존 구독(source·승인 방식·설치 CSV), Authorino 인스턴스, 미승인 InstallPlan
#     switch    source가 다른 기존 구독을 CATALOG_SOURCE·Manual 승인으로 바꾸고 업그레이드 대상 인식을 확인한다(승인은 11-installplan.sh)
#     verify    조회 전용: 의존 Operator CSV Succeeded, Authorino 인스턴스 Ready
#     revert    승인 전에만: 구독 source·channel을 백업 값으로 되돌림(승인 방식은 Manual 유지. 승인 후에는 OLM 다운그레이드 불가 → Red Hat 지원)
#   백업: ${BACKUP_DIR}/maas/sub-<패키지>.before.json
source "$(dirname "$0")/lib/common.sh"
init
CMD=${1:-}
SRC=$CATALOG_SOURCE
B=$(backup_dir maas)

# head_of <package> <channel>: 카탈로그 채널 head "CSV<TAB>버전<TAB>skipRange"
head_of() {
  oc get packagemanifests -n openshift-marketplace -l "catalog=$SRC" -o json 2>/dev/null \
    | jq -r --arg p "$1" --arg c "$2" '[.items[] | select(.metadata.name == $p) | .status.channels[]? | select(.name == $c)
        | [.currentCSV, .currentCSVDesc.version, (.currentCSVDesc.annotations["olm.skipRange"] // "-")] | @tsv][0] // empty'
}
sub_field() { oc get subscriptions.operators.coreos.com "${1#*/}" -n "${1%/*}" -o jsonpath="$2" 2>/dev/null; }
# in_range <버전> <skipRange>: '>=a <b' 형식만 판정한다(그 외 형식은 실패 → switch 후 업그레이드 대상 인식 여부로 판단).
in_range() {
  local v=$1 lo hi
  lo=$(sed -n 's/.*>=[[:space:]]*\([0-9][0-9.]*\).*/\1/p' <<<"$2")
  hi=$(sed -n 's/.*<[[:space:]]*\([0-9][0-9.]*\).*/\1/p' <<<"$2")
  [[ -n "$lo" && -n "$hi" && "$v" != "$hi" ]] || return 1
  [[ "$(printf '%s\n%s\n' "$lo" "$v" | sort -V | head -n1)" == "$lo" && "$(printf '%s\n%s\n' "$v" "$hi" | sort -V | head -n1)" == "$v" ]]
}

case "$CMD" in
  precheck)
    FAIL=0; bad() { warn "$*"; FAIL=$((FAIL + 1)); }
    step "RHCL 카탈로그 $SRC"
    ST=$(oc get catalogsource "$SRC" -n openshift-marketplace -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || true)
    [[ "$ST" == READY ]] && ok "CatalogSource READY" || bad "CatalogSource $SRC: ${ST:-없음}"
    H=$(head_of rhcl-operator "$RHCL_CHANNEL" | cut -f1)
    [[ -n "$H" && ( -z "$RHCL_STARTING_CSV" || "$H" == "$RHCL_STARTING_CSV" ) ]] && ok "rhcl-operator $RHCL_CHANNEL head=$H" \
      || bad "rhcl-operator $RHCL_CHANNEL head=${H:-없음}(기대 ${RHCL_STARTING_CSV:-지정 없음})"

    step "의존 Operator: 카탈로그 head ↔ 기존 구독"
    for p in $RHCL_DEPS; do
      IFS=$'\t' read -r CSV VER SKIP <<<"$(head_of "$p" "$RHCL_DEPS_CHANNEL")"
      [[ -n "${CSV:-}" ]] || { bad "$p: $SRC/$RHCL_DEPS_CHANNEL 에 없음 → 반입 필요"; continue; }
      S=$(find_subscription "$p")
      if [[ -z "$S" ]]; then ok "$p: 구독 없음 → RHCL 승인 때 $CSV 신규 설치"; continue; fi
      INST=$(sub_field "$S" '{.status.installedCSV}'); SSRC=$(sub_field "$S" '{.spec.source}'); APPR=$(sub_field "$S" '{.spec.installPlanApproval}')
      log "$p: 구독 $S source=$SSRC approval=$APPR installed=${INST:-없음} / $SRC head=$CSV($VER) skipRange=$SKIP"
      if [[ "$SSRC" == "$SRC" && "$INST" == "$CSV" ]]; then ok "$p: 이미 $CSV"; continue; fi
      [[ "$SSRC" == "$SRC" ]] || warn "$p: 구독 카탈로그가 $SSRC → switch 필요"
      if [[ -n "$INST" && "$INST" != "$CSV" ]]; then
        if in_range "${INST##*.v}" "$SKIP"; then ok "$p: skipRange가 ${INST##*.v} 포함 → $CSV 로 한 번에 업그레이드(Operator·인스턴스 재기동)"
        else warn "$p: skipRange($SKIP)로 ${INST##*.v} → $VER 경로를 판정하지 못함 → switch 후 업그레이드 대상 인식 여부로 확인"; fi
      fi
    done

    step "Authorino 인스턴스(authorino-operator 업그레이드 때 재기동)"
    A=$( (oc get authorinos.operator.authorino.kuadrant.io -A --no-headers 2>/dev/null || true) | awk '{print $1"/"$2}' | xargs)
    [[ -n "$A" ]] && warn "Authorino 인스턴스: $A → 사용처 담당자에게 재기동 공지" || ok "Authorino 인스턴스 없음"
    # 60-rhcl.sh와 같은 기준. 되돌릴 수 없는 업그레이드 전에 결정한다(이름이 authorino인 CR은 kuadrant의 authorino와 RBAC 충돌, TS-19).
    O=$(tr ' ' '\n' <<<"$A" | grep -v '^kuadrant-system/' | xargs || true)
    if [[ -n "$O" ]] && ! is_on "${AUTHORINO_DUP_ACK:-false}"; then
      bad "kuadrant-system 외 Authorino CR: $O → 사용처 확인 후 정리하거나, 유지하면 AUTHORINO_DUP_ACK=true로 다시 실행(이후 60-rhcl.sh도 같은 값 필요)"
    elif [[ -n "$O" ]]; then
      warn "kuadrant-system 외 Authorino CR 유지(AUTHORINO_DUP_ACK=true): $O"
      tr ' ' '\n' <<<"$O" | grep -q '/authorino$' && warn "이름이 authorino인 CR이 있어 재부팅 후 MaaS 401 위험(TS-19)" || true
    fi

    step "openshift-operators 미승인 InstallPlan(함께 승인되지 않게 확인)"
    oc get installplan -n openshift-operators -o json \
      | jq -r '.items[] | select(.spec.approved | not) | "  \(.metadata.name) \(.spec.clusterServiceVersionNames | join(","))"'
    [[ -s "$B/subscriptions.yaml" ]] && ok "사전 백업 있음: $B" || bad "사전 백업 없음(01-backup.sh maas)"
    ((FAIL == 0)) && ok "사전 점검 통과" || die "사전 점검 실패 ${FAIL}건"
    ;;

  switch)
    N=0
    for p in $RHCL_DEPS; do
      S=$(find_subscription "$p"); [[ -n "$S" ]] || continue
      if [[ "$(sub_field "$S" '{.spec.source}')" == "$SRC" ]]; then ok "$p: 이미 $SRC"; continue; fi
      T=$(head_of "$p" "$RHCL_DEPS_CHANNEL" | cut -f1)
      [[ -n "$T" ]] || die "$p: $SRC/$RHCL_DEPS_CHANNEL 에 없음"
      save_once "$B/sub-$p.before.json" oc get subscriptions.operators.coreos.com "${S#*/}" -n "${S%/*}" -o json
      [[ -s "$B/sub-$p.before.json" ]] || die "$p 구독 백업 실패: $B"
      confirm "$p 구독($S)을 $SRC/$RHCL_DEPS_CHANNEL, Manual 승인으로 바꿉니까?(승인 전까지 업그레이드되지 않음)"
      # source와 승인 방식을 한 번에 바꾼다(Automatic 구독이 source 변경 즉시 업그레이드되지 않게).
      k_patch subscriptions.operators.coreos.com "${S#*/}" "${S%/*}" merge \
        "{\"spec\":{\"source\":\"$SRC\",\"sourceNamespace\":\"openshift-marketplace\",\"channel\":\"$RHCL_DEPS_CHANNEL\",\"installPlanApproval\":\"Manual\"}}"
      N=$((N + 1))
      is_dry_run && continue
      INST=$(sub_field "$S" '{.status.installedCSV}')
      # 설치된 CSV와 다른 currentCSV가 잡히면 업그레이드 경로를 찾은 것이다(중간 버전을 거칠 수도 있음).
      if wait_for "$p 업그레이드 대상 인식" 180 bash -c "c=\$(oc get subscriptions.operators.coreos.com '${S#*/}' -n '${S%/*}' -o jsonpath='{.status.currentCSV}'); [[ -n \"\$c\" && \"\$c\" != '$INST' ]]"; then
        C=$(sub_field "$S" '{.status.currentCSV}')
        [[ "$C" == "$T" ]] && ok "$p: $INST → $C" || warn "$p: 중간 버전 $C 를 거칩니다(승인 후 다시 switch 결과 확인, 최종 $T)."
        log "다음: bash scripts/11-installplan.sh $p $C 로 CSV 목록 확인 후 승인"
      else
        oc get subscriptions.operators.coreos.com "${S#*/}" -n "${S%/*}" -o json \
          | jq -r '.status.conditions[]? | "  \(.type)=\(.status) \(.message // "" | .[0:200])"'
        # 해석 실패(ResolutionFailed)는 openshift-operators의 다른 Operator 해석도 막으므로 바로 되돌린다.
        die "$p: $INST → $T 업그레이드 경로를 찾지 못했습니다. 바로 'DRY_RUN=false bash scripts/12-rhcl-deps.sh revert'로 되돌리고 담당자와 협의한다."
      fi
    done
    ((N > 0)) || ok "바꿀 구독 없음"
    oc get installplan -n openshift-operators
    ;;

  verify)
    for p in $RHCL_DEPS rhcl-operator; do
      S=$(find_subscription "$p"); [[ -n "$S" ]] || { log "$p: 구독 없음"; continue; }
      I=$(sub_field "$S" '{.status.installedCSV}')
      PH=$(oc get csv "$I" -n "${S%/*}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
      [[ "$PH" == Succeeded ]] && ok "$p: $I Succeeded (source=$(sub_field "$S" '{.spec.source}'))" || warn "$p: ${I:-없음} ${PH:-?}"
    done
    (oc get authorinos.operator.authorino.kuadrant.io -A -o json 2>/dev/null || echo '{"items":[]}') \
      | jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name) \([.status.conditions[]? | select(.type == "Ready") | .status][0] // "?")"' \
      | while read -r ns n r; do
          D=$(oc get deploy "$n" -n "$ns" -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null || echo '-')
          [[ "$r" == True ]] && ok "Authorino $ns/$n Ready (Deployment $D)" || warn "Authorino $ns/$n Ready=$r (Deployment $D)"
        done
    ;;

  revert)
    N=0
    for p in $RHCL_DEPS; do
      F="$B/sub-$p.before.json"; [[ -s "$F" ]] || continue
      S=$(find_subscription "$p"); [[ -n "$S" ]] || { warn "$p: 구독 없음"; continue; }
      BEFORE=$(jq -r '.status.installedCSV // empty' "$F"); NOW=$(sub_field "$S" '{.status.installedCSV}')
      [[ "$NOW" == "$BEFORE" ]] || die "$p: 이미 $NOW 설치됨(이전 $BEFORE) → 구독만 되돌릴 수 없습니다(OLM 다운그레이드 불가, Red Hat 지원 요청)."
      # 승인된 설치가 진행 중이면(installedCSV가 아직 이전 값) 되돌리지 않는다.
      IPN=$(sub_field "$S" '{.status.installPlanRef.name}')
      if [[ -n "$IPN" ]] && [[ "$(oc get installplan "$IPN" -n "${S%/*}" -o jsonpath='{.spec.approved}' 2>/dev/null)" == true ]] \
         && oc get installplan "$IPN" -n "${S%/*}" -o jsonpath='{.spec.clusterServiceVersionNames}' 2>/dev/null | grep -q "$p" \
         && [[ "$(sub_field "$S" '{.status.currentCSV}')" != "$BEFORE" ]]; then
        die "$p: 승인된 InstallPlan $IPN 이 설치 중입니다 → 구독을 되돌리지 않습니다(완료 후 verify, 문제 시 Red Hat 지원)."
      fi
      P=$(jq -c '{spec:{source:.spec.source, sourceNamespace:.spec.sourceNamespace, channel:.spec.channel}}' "$F")
      confirm "$p 구독을 백업 값($P)으로 되돌립니까?(승인 방식은 Manual 유지)"
      k_patch subscriptions.operators.coreos.com "${S#*/}" "${S%/*}" merge "$P"
      log "$p: 원래 승인 방식은 $(jq -r '.spec.installPlanApproval' "$F"). 미승인 InstallPlan을 정리한 뒤 필요하면 되돌린다."
      N=$((N + 1))
    done
    ((N > 0)) || warn "되돌릴 백업 없음($B/sub-*.before.json)"
    # 남은 미승인 InstallPlan을 나중에 실수로 승인하지 않도록 이름을 보여 준다.
    PEND=$(oc get installplan -n openshift-operators -o json | jq -r '.items[] | select(.spec.approved | not) | "\(.metadata.name) \(.spec.clusterServiceVersionNames | join(","))"')
    if [[ -n "$PEND" ]]; then
      warn "미승인 InstallPlan(승인하지 말 것, 필요 없으면 oc delete installplan <이름> -n openshift-operators):"
      sed 's/^/    /' <<<"$PEND"
    fi
    ;;
  *) die "사용: $0 precheck|switch|verify|revert" ;;
esac
