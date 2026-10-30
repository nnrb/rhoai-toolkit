#!/usr/bin/env bash
# MaaS 인증·토큰 제한 기반: Kuadrant 인스턴스 + Authorino TLS 부트스트랩
#   선행: 10-operators.sh (rhcl-operator)
#   반영한 현장 이슈: TS-05(CA 파일 미마운트), TS-19(Authorino CR 중복 → RBAC 충돌)
source "$(dirname "$0")/lib/common.sh"
init envsubst

is_on "$FEATURE_MAAS" || { log "FEATURE_MAAS=false: 건너뜁니다."; exit 0; }

step "1. RHCL Operator"
RHCL_SUB=$(find_subscription rhcl-operator)
if [[ -z "$RHCL_SUB" ]]; then
  if is_dry_run; then warn "[dry-run] rhcl-operator 구독이 아직 없어 이후 단계를 검증할 수 없습니다(10-operators.sh 적용 후 재실행)."; exit 0; fi
  die "rhcl-operator 구독이 없습니다. 10-operators.sh를 먼저 실행하세요."
fi
RHCL_NS=${RHCL_SUB%/*}
csv_succeeded "$RHCL_NS" rhcl-operator || is_dry_run || die "rhcl-operator CSV가 Succeeded가 아닙니다."
ok "RHCL 구독: $RHCL_SUB"

step "2. Authorino CR 중복 확인 (TS-19)"
OTHERS=$(oc get authorinos.operator.authorino.kuadrant.io -A -o json 2>/dev/null \
  | jq -r '[.items[] | select(.metadata.namespace != "kuadrant-system") | "\(.metadata.namespace)/\(.metadata.name)"] | join(" ")' || true)
if [[ -n "$OTHERS" ]]; then
  warn "kuadrant-system 외 Authorino CR: $OTHERS"
  warn "이름이 같으면 ClusterRoleBinding을 공유해 재부팅 후 MaaS 인증이 401로 실패합니다."
  is_on "${AUTHORINO_DUP_ACK:-false}" || die "사용 여부를 확인·정리한 뒤 AUTHORINO_DUP_ACK=true로 다시 실행하세요(docs/90-troubleshooting.md TS-19)."
else
  ok "다른 Authorino CR 없음"
fi

step "3. Kuadrant 인스턴스"
apply_template "$TOOLKIT_ROOT/manifests/maas/kuadrant.yaml"
kuadrant_ready() { [[ "$(oc get kuadrant kuadrant -n kuadrant-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" == "True" ]]; }
wait_for "Kuadrant Ready" 600 kuadrant_ready || warn "Kuadrant가 Ready가 아닙니다: oc describe kuadrant kuadrant -n kuadrant-system"
wait_for "Authorino CR 생성" 300 oc get authorino authorino -n kuadrant-system || true

step "4. 인증 timeout (AUTH_SERVICE_TIMEOUT=$RHCL_AUTH_TIMEOUT)"
SUB_JSON=$(oc get subscriptions.operators.coreos.com -n "$RHCL_NS" "${RHCL_SUB#*/}" -o json)
CUR_TIMEOUT=$(jq -r '.spec.config.env[]? | select(.name == "AUTH_SERVICE_TIMEOUT") | .value' <<<"$SUB_JSON")
if [[ "$CUR_TIMEOUT" == "$RHCL_AUTH_TIMEOUT" ]]; then
  ok "이미 설정됨"
else
  # 기존 env 목록을 보존하고 AUTH_SERVICE_TIMEOUT만 추가·수정한다.
  NEW_ENV=$(jq -c --arg v "$RHCL_AUTH_TIMEOUT" \
    '[(.spec.config.env // [])[] | select(.name != "AUTH_SERVICE_TIMEOUT")] + [{"name":"AUTH_SERVICE_TIMEOUT","value":$v}]' <<<"$SUB_JSON")
  backup subscriptions.operators.coreos.com "${RHCL_SUB#*/}" "$RHCL_NS"
  k_patch subscriptions.operators.coreos.com "${RHCL_SUB#*/}" "$RHCL_NS" merge "{\"spec\":{\"config\":{\"env\":$NEW_ENV}}}"
fi

step "5. Authorino TLS 부트스트랩"
SVC=authorino-authorino-authorization
# Kuadrant 직후에는 Authorino Service·Deployment가 아직 없을 수 있다. 없으면 인증서가 발급되지 않아 TLS가 깨진다.
if ! is_dry_run; then
  wait_for "Authorino Service" 300 oc get service "$SVC" -n kuadrant-system \
    || die "Service $SVC 가 생성되지 않았습니다: oc get authorino authorino -n kuadrant-system -o yaml"
  wait_for "Authorino Deployment" 300 oc get deployment authorino -n kuadrant-system \
    || die "Deployment authorino 가 생성되지 않았습니다."
fi
k_patch service "$SVC" kuadrant-system merge \
  '{"metadata":{"annotations":{"service.beta.openshift.io/serving-cert-secret-name":"authorino-server-cert"}}}'
apply_template "$TOOLKIT_ROOT/manifests/maas/authorino-service-ca.yaml"
backup authorino authorino kuadrant-system
# listener TLS + service CA 마운트(볼륨 없이 env만 있으면 CA 파일이 없어 검증 실패: TS-05)
# merge patch는 배열을 통째로 바꾸므로 기존 volumes.items를 보존해 합친다.
CUR_VOLS=$(oc get authorino authorino -n kuadrant-system -o json 2>/dev/null | jq -c '.spec.volumes.items // []' || echo '[]')
NEW_VOLS=$(jq -c '[.[] | select(.name != "openshift-service-ca")] + [{
    "name": "openshift-service-ca",
    "mountPath": "/etc/ssl/certs/openshift-service-ca",
    "configMaps": ["openshift-service-ca-bundle"],
    "items": [{"key": "service-ca.crt", "path": "service-ca-bundle.crt"}]
  }]' <<<"$CUR_VOLS")
k_patch authorino authorino kuadrant-system merge "$(jq -cn --argjson v "$NEW_VOLS" '{
  spec: {
    listener: {tls: {enabled: true, certSecretRef: {name: "authorino-server-cert"}}},
    volumes: {items: $v}
  }
}')"
CA=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt
if is_dry_run; then
  log "[dry-run] oc set env deployment/authorino -n kuadrant-system SSL_CERT_FILE=$CA REQUESTS_CA_BUNDLE=$CA"
else
  oc set env deployment/authorino -n kuadrant-system SSL_CERT_FILE="$CA" REQUESTS_CA_BUNDLE="$CA"
  oc rollout status deployment/authorino -n kuadrant-system --timeout=300s
fi

step "6. 확인"
if ! is_dry_run; then
  SA=system:serviceaccount:kuadrant-system:authorino-authorino
  if oc auth can-i create tokenreviews.authentication.k8s.io --as="$SA" >/dev/null 2>&1; then
    ok "Authorino SA tokenreviews 권한"
  else
    warn "Authorino SA에 tokenreviews 권한이 없습니다(TS-19 확인)."
  fi
  if oc exec -n kuadrant-system deployment/authorino -- test -s "$CA" 2>/dev/null; then
    ok "CA 파일 마운트 확인: $CA"
  else
    warn "Authorino Pod에서 CA 파일을 확인하지 못했습니다(TS-05)."
  fi
fi
oc get kuadrant,authorino,limitador -n kuadrant-system 2>/dev/null || true

step "7. KServe 컨트롤러 재시작"
# RHCL을 RHOAI보다 나중에 설치했으면 llm-d 인증 연동을 위해 두 컨트롤러를 재시작한다(모델 Pod에는 영향 없음).
if is_dry_run; then
  log "[dry-run] oc rollout restart deployment/odh-model-controller deployment/kserve-controller-manager -n $AI_NS"
elif is_on "${RESTART_KSERVE_CONTROLLERS:-true}"; then
  for d in odh-model-controller kserve-controller-manager; do
    if oc get deployment "$d" -n "$AI_NS" >/dev/null 2>&1; then
      oc rollout restart "deployment/$d" -n "$AI_NS"
      oc rollout status "deployment/$d" -n "$AI_NS" --timeout=300s || warn "$d 재시작 확인 실패"
    fi
  done
fi
