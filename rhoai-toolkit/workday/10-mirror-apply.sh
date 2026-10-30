#!/usr/bin/env bash
# 미러 설정 적용(03 RHOAI 3.4.2 작업계획서 4단계, 05 RHOAI 3.5.1 작업계획서 3단계): oc-mirror 결과 IDMS/ITMS/CatalogSource를 GPU worker 풀 pause 전에 적용한다.
#   - oc-mirror 결과의 IDMS/ITMS 객체 이름에 -202611을 붙인 사본을 적용한다(기존 idms-generic-0·itms-generic-0·idms-release-0 덮어쓰기 방지).
#   - 기존 매핑 삭제가 있으면 중단한다(추가만 허용).
#   - registries.conf 변경 정책이 Reboot이면 중단한다(GPU 풀 재부팅이 생기므로 담당자와 일정 협의).
#   - 적용 후 모든 MCP가 UPDATED=True가 될 때까지 기다리고, 노드 bootID와 운영 모델 Pod가 그대로인지 확인한다.
#   사용: ./10-mirror-apply.sh                 (DRY_RUN=true: diff·서버 dry-run만)
#         DRY_RUN=false ./10-mirror-apply.sh   (실제 적용)
source "$(dirname "$0")/lib/common.sh"
load_env
require oc jq
# MIRROR_PROFILE=rhoai351: RHOAI 3.5.1 반입분(RHOAI351_MIRROR_DIR, 접미사 -rhoai351)만 적용
if [[ "${MIRROR_PROFILE:-}" == rhoai351 ]]; then FEATURE_MIRROR_DIR=${RHOAI351_MIRROR_DIR:-}; MIRROR_DIR=""; MIRROR_SUFFIX=-rhoai351; fi
filled MIRROR_DIR || filled FEATURE_MIRROR_DIR || die "MIRROR_DIR·FEATURE_MIRROR_DIR 중 하나 이상을 config/env.sh에 지정하세요."
evidence_dir
exec > >(tee "$EVID/10-mirror-apply-$(date +%H%M%S).txt") 2>&1
BACKUP_DIR="$BACKUP_DIR/mirror${MIRROR_SUFFIX:--202611}"; mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"

REL="${MIRROR_DIR:-/nonexistent}/working-dir/cluster-resources"
FEA="${FEATURE_MIRROR_DIR:-/nonexistent}/working-dir/cluster-resources"
filled MIRROR_DIR || REL=/nonexistent
filled FEATURE_MIRROR_DIR || FEA=/nonexistent
COPY="$WORK_ROOT/manifests/mirror${MIRROR_SUFFIX:--202611}"
# oc-mirror v2 결과(idms-oc-mirror.yaml·itms-oc-mirror.yaml)를 객체 이름에 MIRROR_SUFFIX를 붙여 복사한다(기존 idms-generic-0 등 덮어쓰기 방지).
#   반입마다 다른 접미사를 쓴다(3.4.2 기능: -202611, 3.5.1: -rhoai351). 같은 접미사로 다른 반입분을 적용하면 앞 반입분 매핑이 지워진다.
[[ -d "$REL" ]] && mirror_copy "$REL" "$COPY/release"
[[ -d "$FEA" ]] && mirror_copy "$FEA" "$COPY/feature"
FILES=()
for f in "$COPY"/release/*.yaml "$COPY"/feature/*.yaml "$FEA"/cs-*.yaml; do [[ -f "$f" ]] && FILES+=("$f"); done
((${#FILES[@]} > 0)) || die "적용할 cluster-resources 파일이 없습니다."

step "1. 대상 파일(IDMS/ITMS는 이름 변경 사본)"
printf '  %s\n' "${FILES[@]}"
grep -h -A0 '^  name:' "$COPY"/release/*.yaml "$COPY"/feature/*.yaml 2>/dev/null | sed 's/^/  적용 이름:/' || true
for n in $(awk '/^  name:/{print $2}' "$COPY"/release/*.yaml "$COPY"/feature/*.yaml 2>/dev/null); do
  oc get imagedigestmirrorset "$n" >/dev/null 2>&1 && warn "같은 이름의 IDMS가 이미 있음: $n(재실행이면 정상)"
  oc get imagetagmirrorset "$n" >/dev/null 2>&1 && warn "같은 이름의 ITMS가 이미 있음: $n(재실행이면 정상)"
done
for p in ${GPU_MCPS:-}; do
  [[ "$(oc get mcp "$p" -o jsonpath='{.spec.paused}')" != "true" ]] || die "MCP $p가 이미 paused입니다. 미러 설정은 pause 전에 적용해야 합니다."
done

step "2. 백업과 diff(기존 매핑 삭제 확인)"
# 백업은 처음 한 번만 만든다(다시 실행해도 적용 전 상태 유지)
[[ -s "$BACKUP_DIR/idms.before-mirror.yaml" ]] || oc get imagedigestmirrorset -o yaml > "$BACKUP_DIR/idms.before-mirror.yaml"
[[ -s "$BACKUP_DIR/itms.before-mirror.yaml" ]] || oc get imagetagmirrorset -o yaml > "$BACKUP_DIR/itms.before-mirror.yaml"
[[ -s "$BACKUP_DIR/catalogsource.before-mirror.yaml" ]] || oc get catalogsource -n openshift-marketplace -o yaml > "$BACKUP_DIR/catalogsource.before-mirror.yaml"
# 재부팅·재기동 판정 기준값은 실행할 때마다 새로 받는다(이전 리허설·OCP 업그레이드 전 값과 비교하지 않게).
PODS_BASE="$EVID/prod-pods.before-mirror${MIRROR_SUFFIX}.txt"; BOOT_BASE="$EVID/node-bootid.before-mirror${MIRROR_SUFFIX}.txt"
oc get pod -n "${PROD_NS:-llm-models}" -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,START:.status.startTime,RESTARTS:.status.containerStatuses[0].restartCount | grep -v otel > "$PODS_BASE" || true
DEL=0
for f in "${FILES[@]}"; do
  oc diff -f "$f" > "$EVID/diff-$(basename "$f").txt" 2>&1 || true
  n=$(deletions_in_diff "$EVID/diff-$(basename "$f").txt")
  if [[ "$n" == "0" ]]; then ok "$(basename "$f"): 추가만 있음"; else fail "$(basename "$f"): 삭제 줄 ${n}개 → $EVID/diff-$(basename "$f").txt"; DEL=1; fi
done
((DEL == 0)) || die "기존 매핑 삭제가 있어 중단합니다(담당자 협의)."
AUTO=$(oc get subscriptions.operators.coreos.com -A -o json | jq -r '.items[] | select(.spec.installPlanApproval != "Manual") | "\(.metadata.namespace)/\(.metadata.name)"')
[[ -z "$AUTO" ]] && ok "모든 Subscription이 Manual" || die "Automatic Subscription이 있습니다(카탈로그 갱신 시 자동 업그레이드 위험): $(echo $AUTO)"

step "3. registries.conf 변경 정책"
POL=$(oc get machineconfiguration cluster -o json 2>/dev/null | jq -c '[.status.nodeDisruptionPolicyStatus.clusterPolicies.files[]? | select(.path=="/etc/containers/registries.conf") | .actions[].type]' || echo '[]')
info "actions=$POL"
[[ "$POL" != *Reboot* ]] || die "registries.conf 변경 시 재부팅 정책입니다. 노드 재부팅이 생기므로 담당자와 일정을 협의하세요."
oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.nodeInfo.bootID}{"\n"}{end}' > "$BOOT_BASE"

step "4. 적용"
for f in "${FILES[@]}"; do oc apply --dry-run=server -f "$f" >/dev/null && ok "dry-run $(basename "$f")" || die "dry-run 실패: $f"; done
if is_dry_run; then info "DRY_RUN=true: 적용하지 않습니다."; summary; exit $?; fi
confirm "IDMS/ITMS/CatalogSource ${#FILES[@]}개 파일을 적용합니까?"
for f in "${FILES[@]}"; do oc apply -f "$f"; done
oc get imagedigestmirrorset; oc get imagetagmirrorset

step "5. MCP 반영 대기(최대 ${MCP_WAIT_MIN:-40}분)"
sleep 30
end=$(( $(date +%s) + ${MCP_WAIT_MIN:-40} * 60 ))
while :; do
  pending=$(oc get mcp --no-headers | awk '$3!="True" || $4!="False" || $5!="False" {print $1}')
  [[ -z "$pending" ]] && { ok "모든 MCP UPDATED=True"; break; }
  (( $(date +%s) < end )) || { fail "시간 초과: $(echo $pending) (작업계획서 복구방안)"; break; }
  log "반영 중: $(echo $pending)"; sleep 30
done
oc get mcp
if oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.nodeInfo.bootID}{"\n"}{end}' | diff "$BOOT_BASE" - ; then
  ok "노드 재부팅 없음"
else
  warn "bootID가 바뀐 노드가 있습니다(재부팅 발생) → 담당자에게 알림"
fi
if [[ -f "$PODS_BASE" ]]; then
  oc get pod -n "${PROD_NS:-llm-models}" -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,START:.status.startTime,RESTARTS:.status.containerStatuses[0].restartCount | grep -v otel \
    | diff "$PODS_BASE" - >/dev/null && ok "운영 모델 재기동 없음" || warn "운영 모델 Pod 변화 있음(diff 확인)"
fi
oc get catalogsource -n openshift-marketplace -o custom-columns=NAME:.metadata.name,STATE:.status.connectionState.lastObservedState
summary
