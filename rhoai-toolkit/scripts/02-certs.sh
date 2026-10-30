#!/usr/bin/env bash
# MaaS Gateway 인증서 파일 준비·검증(클러스터 변경 없음)
#   사용: bash scripts/02-certs.sh maas
#   입력(사내 PKI 발급, ${WORK_ROOT}/certs): maas.crt(SAN=MAAS_HOSTNAME), maas.key, intermediate.crt(없으면 생략), root-ca.crt
#   출력: MAAS_TLS_CERT_FILE(서버+중간 CA), MAAS_CA_FILE(중간 CA+root CA). 키는 출력하지 않는다.
source "$(dirname "$0")/lib/common.sh"
init openssl
[[ "${1:-}" == maas ]] || die "사용: $0 maas"
C="$WORK_ROOT/certs"; mkdir -p "$C"; chmod 700 "$C"
for f in maas.crt maas.key root-ca.crt; do [[ -f "$C/$f" ]] || die "$C/$f 가 없습니다."; done
chmod 600 "$C/maas.key"
INT=""; [[ -f "$C/intermediate.crt" ]] && INT="$C/intermediate.crt"

step "서버 인증서"
openssl x509 -in "$C/maas.crt" -noout -subject -enddate -ext subjectAltName | sed 's/^/  /'
openssl x509 -in "$C/maas.crt" -noout -checkhost "$MAAS_HOSTNAME" 2>/dev/null | grep -q 'does match' && ok "SAN에 $MAAS_HOSTNAME 포함" || die "SAN에 $MAAS_HOSTNAME 없음"
[[ "$(openssl x509 -in "$C/maas.crt" -noout -pubkey | sha256sum)" == "$(openssl pkey -in "$C/maas.key" -pubout | sha256sum)" ]] && ok "인증서·키 일치" || die "인증서·키 불일치"
openssl x509 -in "$C/maas.crt" -noout -checkend $((30 * 86400)) >/dev/null && ok "만료 30일 이상 남음" || warn "30일 이내 만료"
openssl verify -CAfile "$C/root-ca.crt" ${INT:+-untrusted "$INT"} "$C/maas.crt" >/dev/null && ok "체인 검증" || die "체인 검증 실패"

step "파일 생성"
cat "$C/maas.crt" ${INT:+"$INT"} >"$MAAS_TLS_CERT_FILE"
cat ${INT:+"$INT"} "$C/root-ca.crt" >"$MAAS_CA_FILE"
chmod 600 "$MAAS_TLS_CERT_FILE" "$MAAS_CA_FILE"
openssl verify -CAfile "$MAAS_CA_FILE" "$C/maas.crt" >/dev/null && ok "MAAS_CA_FILE로 서버 인증서 검증" || die "MAAS_CA_FILE 검증 실패"
[[ "$MAAS_TLS_KEY_FILE" == "$C/maas.key" ]] || warn "MAAS_TLS_KEY_FILE($MAAS_TLS_KEY_FILE)이 $C/maas.key와 다릅니다."
ok "MAAS_TLS_CERT_FILE=$MAAS_TLS_CERT_FILE, MAAS_CA_FILE=$MAAS_CA_FILE"
