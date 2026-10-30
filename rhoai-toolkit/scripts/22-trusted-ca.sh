#!/usr/bin/env bash
# 사내 CA를 RHOAI 전역 신뢰 번들에 추가한다(DSCI spec.trustedCABundle.customCABundle).
#   RHOAI는 이 값을 각 프로젝트의 ConfigMap odh-trusted-ca-bundle로 배포한다.
#   Workbench·Pipeline·모델 서빙이 내부 S3·레지스트리·DB(사설 CA)에 TLS로 접속할 때 필요하다.
#   기존 customCABundle은 보존하고 새 CA만 덧붙인다.
source "$(dirname "$0")/lib/common.sh"
init openssl

[[ -n "$INTERNAL_CA_FILE" ]] || { log "INTERNAL_CA_FILE이 비어 있어 건너뜁니다."; exit 0; }
[[ -f "$INTERNAL_CA_FILE" ]] || die "CA 파일이 없습니다: $INTERNAL_CA_FILE"
N=$(grep -c 'BEGIN CERTIFICATE' "$INTERNAL_CA_FILE" || true)
((N > 0)) || die "PEM 인증서가 아닙니다: $INTERNAL_CA_FILE"

# 체인 파일(Sub CA + Root CA)이면 인증서마다 나눠 모두 처리한다.
# openssl로 정규화: 헤더 줄(Bag Attributes, subject=)·CRLF를 제거한 순수 PEM. 이미 있는 인증서는 건너뛴다.
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
awk -v d="$TMPD" '/BEGIN CERTIFICATE/ { n++; on = 1 } on { print > (d "/c" n ".pem") } /END CERTIFICATE/ { on = 0 }' "$INTERNAL_CA_FILE"
CUR=$(oc get dscinitialization "$DSCI_NAME" -o jsonpath='{.spec.trustedCABundle.customCABundle}' 2>/dev/null || true)
NEW=""
for f in "$TMPD"/c*.pem; do
  C=$(openssl x509 -in "$f") || die "PEM 인증서를 읽지 못했습니다: $INTERNAL_CA_FILE"
  S=$(openssl x509 -in "$f" -noout -subject -enddate | tr '\n' ' ')
  L=$(sed -n '2p' <<<"$C")   # 인증서 본문 첫 줄로 중복 여부 판단
  if [[ -n "$CUR" ]] && grep -qF -- "$L" <<<"$CUR"; then ok "이미 포함: $S"; continue; fi
  log "추가 대상: $S"
  NEW+="$C"$'\n'
done
log "인증서 ${N}장 중 추가 $(grep -c 'BEGIN CERTIFICATE' <<<"$NEW" || true)장"
if [[ -z "$NEW" ]]; then ok "이미 customCABundle에 모두 포함되어 있습니다."; exit 0; fi

BUNDLE=${NEW%$'\n'}
if [[ -n "$CUR" ]]; then BUNDLE=$(printf '%s\n%s' "$CUR" "$BUNDLE"); fi
backup dscinitialization "$DSCI_NAME"
confirm "DSCI customCABundle에 $INTERNAL_CA_FILE 을 추가합니까?"
k_patch dscinitialization "$DSCI_NAME" "" merge \
  "$(jq -cn --arg b "$BUNDLE" '{spec: {trustedCABundle: {managementState: "Managed", customCABundle: $b}}}')"
log "확인: oc get configmap odh-trusted-ca-bundle -n <프로젝트> -o jsonpath='{.data}' | head"
log "기존 Workbench·모델 Pod는 재시작해야 새 CA를 읽는다."
