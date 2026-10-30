#!/usr/bin/env bash
# 백업 파일의 spec으로 되돌린다.
#   사용: scripts/99-rollback.sh <dashboard|dsc|dsci> <backup-*.yaml>
#   주의: 백업 이후 다른 관리자의 변경도 함께 되돌린다. 이미 만든 Gateway·DB·큐·모델은 삭제하지 않는다.
#         DSC를 되돌려 컴포넌트가 Removed가 되면 그 컴포넌트의 리소스가 삭제될 수 있다.
source "$(dirname "$0")/lib/common.sh"
init

TARGET=${1:-}; FILE=${2:-}
[[ -n "$TARGET" && -f "$FILE" ]] || die "사용: $0 <dashboard|dsc|dsci> <backup-*.yaml>"

case "$TARGET" in
  dashboard) KIND=odhdashboardconfig; NAME=$DASH_NAME; NS=$AI_NS ;;
  dsc)       KIND=datasciencecluster; NAME=$DSC_NAME; NS="" ;;
  dsci)      KIND=dscinitialization;  NAME=$DSCI_NAME; NS="" ;;
  *) die "대상은 dashboard | dsc | dsci" ;;
esac

SPEC=$(oc create --dry-run=client -f "$FILE" -o json | jq -c '.spec')
[[ "$SPEC" != "null" ]] || die "백업 파일에 spec이 없습니다."
backup "$KIND" "$NAME" "$NS"
log "spec 차이 (- 현재 / + 복원):"
diff -u <(oc get "$KIND" "$NAME" ${NS:+-n "$NS"} -o json | jq -S '.spec') <(jq -S . <<<"$SPEC") || true
confirm "$KIND/$NAME 의 spec을 $FILE 내용으로 교체합니까?"
k_patch "$KIND" "$NAME" "$NS" json "$(jq -cn --argjson s "$SPEC" '[{"op":"replace","path":"/spec","value":$s}]')"
