#!/usr/bin/env bash
# MaaS 동작 검증(검증 모델 MODEL_NS/MODEL_NAME, 테스트 사용자 MAAS_TEST_USER)
#   하위 명령
#     db         MaaS DB 연결·스키마·영속성(PVC) 확인
#     user       테스트 사용자 토큰으로 maas-api 기본 동작(health 200, 인증 없음 401, 모델 목록) — 비밀번호는 oc login이 입력받음
#     prepare    테스트 Group·MaaSSubscription(분당 MAAS_TEST_LIMIT token)·MaaSAuthPolicy 생성(기본 dry-run)
#     key        Dashboard에서 발급한 API key를 입력받아 KEYS_FILE(권한 600)에 저장하고 모델 목록을 확인
#     auth       M01 key 없음 401 / M02 정상 200 / M03 한도 300 임시 축소 후 429 / M04 65초 뒤 200 / 한도 원복
#     stability  20회 연속 200, M05 폐기 key 401·403, M06 maas-api 재시작 후 key 유지, M07 Authorino x509 오류 0
#     evidence   구성 상태·정책·API key 목록(key 값 제외)·DB 덤프(권한 600) 저장
#     cleanup    테스트 사용자 kubeconfig 로그아웃, KEYS_FILE 삭제
#   key·token은 화면·증적에 남기지 않는다.
source "$(dirname "$0")/lib/common.sh"
init curl
CMD=${1:-}
MAAS_HOST=$MAAS_HOSTNAME
MODEL_URL="https://${MAAS_HOST}/${MODEL_NS}/${MODEL_NAME}"
UKC="$WORK_ROOT/user.kubeconfig"
RESP=$(mktemp); trap 'rm -f "$RESP"' EXIT
need_ca() { [[ -f "$MAAS_CA_FILE" ]] || die "MAAS_CA_FILE이 없습니다: $MAAS_CA_FILE (02-certs.sh maas)"; }
API_NS=$(oc get deploy -A -o json | jq -r '[.items[] | select(.metadata.name=="maas-api") | .metadata.namespace][0] // empty')
API_NS=${API_NS:-$AI_NS}   # 3.4: redhat-ods-applications, 3.5: infra namespace

# call <key>: 채팅 1건 → HTTP 코드 출력(응답은 $RESP)
call() {
  curl -sS --cacert "$MAAS_CA_FILE" -o "$RESP" -w '%{http_code}' -m 60 \
    -K <(bearer "$1") -H 'Content-Type: application/json' \
    -d "{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"한 문장으로 자기소개\"}],\"max_tokens\":100}" \
    "${MODEL_URL}/v1/chat/completions" || true
}
load_key() { need_ca; [[ -s "$KEYS_FILE" ]] || die "$KEYS_FILE 이 없습니다(key 먼저)."; source "$KEYS_FILE"; [[ -n "${KEY_A:-}" ]] || die "KEY_A가 비어 있습니다."; }
expect() { # expect <이름> <기대 코드 정규식> <실제>
  if [[ "$3" =~ ^($2)$ ]]; then ok "$1 → $3"; else warn "$1 → $3 (기대 $2)"; fi
}
set_limit() {
  k_patch maassubscriptions.maas.opendatahub.io maas-test models-as-a-service json \
    "[{\"op\":\"replace\",\"path\":\"/spec/modelRefs/0/tokenRateLimits/0/limit\",\"value\":$1}]"
  is_dry_run || { sleep 30; log "TokenRateLimitPolicy 한도: $(oc get tokenratelimitpolicy -n "$MODEL_NS" -o json | jq -c '[.items[].spec | .. | .limit? // empty]')"; }
}

case "$CMD" in
  db)
    step "MaaS DB"
    oc logs deploy/maas-api -n "$API_NS" --tail=50 | grep -E 'schema|Connected' || warn "maas-api 로그에 DB 연결 기록이 없습니다."
    oc exec -n "$MAAS_DB_NS" deploy/maas-postgresql -- psql -d maas -c '\dt'
    oc exec -n "$MAAS_DB_NS" deploy/maas-postgresql -- df -h /var/lib/pgsql/data
    if ! is_dry_run; then
      confirm "영속성 시험(표 생성 → DB Pod 재시작 → 확인 → 표 삭제)을 합니까?"
      oc exec -n "$MAAS_DB_NS" deploy/maas-postgresql -- psql -d maas -c "CREATE TABLE IF NOT EXISTS persist_check(t timestamptz default now()); INSERT INTO persist_check DEFAULT VALUES;"
      trap 'oc exec -n "$MAAS_DB_NS" deploy/maas-postgresql -- psql -d maas -c "DROP TABLE IF EXISTS persist_check;" >/dev/null 2>&1 || true; rm -f "$RESP"' EXIT
      oc delete pod -n "$MAAS_DB_NS" -l app=maas-postgresql
      sleep 10; oc wait --for=condition=Ready pod -l app=maas-postgresql -n "$MAAS_DB_NS" --timeout=300s
      N=$(oc exec -n "$MAAS_DB_NS" deploy/maas-postgresql -- psql -d maas -tAc "select count(*) from persist_check;")
      [[ "$N" -ge 1 ]] && ok "재시작 후 데이터 유지($N)" || warn "데이터 유지 실패"
      oc exec -n "$MAAS_DB_NS" deploy/maas-postgresql -- psql -d maas -c "DROP TABLE persist_check;"
    fi
    ;;

  user)
    step "테스트 사용자($MAAS_TEST_USER) 기본 동작"; need_ca
    [[ "${MAAS_TEST_USER:0:1}" != "<" ]] || die "config/env.sh의 MAAS_TEST_USER를 지정하세요."
    oc login --kubeconfig="$UKC" -u "$MAAS_TEST_USER" "$(oc whoami --show-server)" </dev/tty
    chmod 600 "$UKC"
    TOKEN=$(oc --kubeconfig="$UKC" whoami -t)
    expect "health" 200 "$(curl -sS --cacert "$MAAS_CA_FILE" -o /dev/null -w '%{http_code}' "https://${MAAS_HOST}/maas-api/health" || true)"
    expect "models(인증 없음)" 401 "$(curl -sS --cacert "$MAAS_CA_FILE" -o /dev/null -w '%{http_code}' "https://${MAAS_HOST}/maas-api/v1/models" || true)"
    expect "models(사용자 토큰)" 200 "$(curl -sS --cacert "$MAAS_CA_FILE" -o "$RESP" -w '%{http_code}' -K <(bearer "$TOKEN") "https://${MAAS_HOST}/maas-api/v1/models" || true)"
    unset TOKEN
    jq -c '.' "$RESP" 2>/dev/null | head -c 400; echo
    oc get authpolicy,tokenratelimitpolicy -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,ENFORCED:'.status.conditions[?(@.type=="Enforced")].status'
    ;;

  prepare)
    step "테스트 Group·MaaSSubscription·MaaSAuthPolicy"
    [[ "${MAAS_TEST_USER:0:1}" != "<" ]] || die "config/env.sh의 MAAS_TEST_USER를 지정하세요."
    f="$EVIDENCE_DIR/maas-test-resources.yaml"
    cat >"$f" <<EOF
apiVersion: user.openshift.io/v1
kind: Group
metadata:
  name: ${MAAS_TEST_GROUP}
users:
  - ${MAAS_TEST_USER}
---
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSSubscription
metadata:
  name: maas-test
  namespace: models-as-a-service
spec:
  owner:
    groups:
      - name: ${MAAS_TEST_GROUP}
  priority: 100
  modelRefs:
    - name: ${MODEL_NAME}
      namespace: ${MODEL_NS}
      tokenRateLimits:
        - limit: ${MAAS_TEST_LIMIT}
          window: 1m
      billingRate:
        perToken: "0.000002"
  tokenMetadata:
    costCenter: cc-ai-test
    organizationId: bcnuri
    labels:
      env: test
---
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSAuthPolicy
metadata:
  name: model-test-access
  namespace: models-as-a-service
spec:
  modelRefs:
    - name: ${MODEL_NAME}
      namespace: ${MODEL_NS}
  subjects:
    groups:
      - name: ${MAAS_TEST_GROUP}
  meteringMetadata:
    costCenter: cc-ai-test
    organizationId: bcnuri
    labels:
      env: test
EOF
    confirm "테스트 Group·MaaSSubscription·MaaSAuthPolicy를 만듭니까?"
    k_apply "$f"
    if ! is_dry_run; then
      sleep 20
      oc get maassubscriptions.maas.opendatahub.io,maasauthpolicies.maas.opendatahub.io -n models-as-a-service
      oc get authpolicy,tokenratelimitpolicy -n "$MODEL_NS" -o custom-columns=NAME:.metadata.name,ENFORCED:'.status.conditions[?(@.type=="Enforced")].status'
    fi
    ;;

  key)
    step "API key 입력(Dashboard: Models as a Service → API keys → Create, $MAAS_TEST_USER로 로그인)"
    if [[ -e "$KEYS_FILE" ]]; then die "기존 파일이 있습니다: $KEYS_FILE (cleanup 후 다시)"; fi
    IFS= read -r -s -p "KEY_A 입력: " v </dev/tty; echo
    [[ -n "$v" ]] || die "빈 key"
    ( umask 077; set -o noclobber; printf 'KEY_A=%q\n' "$v" >"$KEYS_FILE" )
    unset v; chmod 600 "$KEYS_FILE"; ok "저장: $KEYS_FILE (권한 600)"
    load_key
    expect "models(KEY_A)" 200 "$(curl -sS --cacert "$MAAS_CA_FILE" -o "$RESP" -w '%{http_code}' -K <(bearer "$KEY_A") "https://${MAAS_HOST}/maas-api/v1/models" || true)"
    jq -c '[.data[]? | {id, ready}]' "$RESP" 2>/dev/null || true
    ;;

  auth)
    load_key
    step "M01·M02"
    expect "M01 key 없음" 401 "$(curl -sS --cacert "$MAAS_CA_FILE" -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
      -d "{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" "${MODEL_URL}/v1/chat/completions" || true)"
    expect "M02 정상 key" 200 "$(call "$KEY_A")"; jq -c '.usage' "$RESP" 2>/dev/null || true
    step "M03·M04 한도(분당 300 token 임시 축소 → 원복 ${MAAS_TEST_LIMIT})"
    if is_dry_run; then log "[dry-run] 한도 변경 시험은 DRY_RUN=false에서만 수행"; else
      confirm "MaaSSubscription maas-test 한도를 300으로 임시 축소합니까?(시험 후 ${MAAS_TEST_LIMIT}으로 원복)"
      trap 'set_limit "$MAAS_TEST_LIMIT" || true; rm -f "$RESP"' EXIT
      set_limit 300
      codes=""; for i in 1 2 3 4 5 6; do codes="$codes $(call "$KEY_A")"; done
      [[ "$codes" == *429* ]] && ok "M03 한도 초과 429 확인:$codes" || warn "M03 429 없음:$codes"
      sleep 65; expect "M04 65초 후" 200 "$(call "$KEY_A")"
      set_limit "$MAAS_TEST_LIMIT"; trap 'rm -f "$RESP"' EXIT
    fi
    ;;

  stability)
    load_key
    step "연속 20회"
    codes=""; for i in $(seq 1 20); do codes="$codes $(call "$KEY_A")"; done
    [[ "$(tr ' ' '\n' <<<"$codes" | grep -cvE '^(200|)$' || true)" == 0 ]] && ok "20회 모두 200" || warn "응답:$codes"
    oc get pod -n "$MODEL_NS" | grep "$MODEL_NAME" || true
    step "M05 폐기 key(Dashboard에서 key 1개를 추가 발급 → 폐기한 뒤 입력, 생략은 Enter)"
    IFS= read -r -s -p "폐기한 key: " KR </dev/tty; echo
    if [[ -n "$KR" ]]; then expect "M05 폐기 key" "401|403" "$(call "$KR")"; fi; unset KR
    step "M06 maas-api 재시작 후 key 유지"
    if is_dry_run; then log "[dry-run] maas-api 재시작은 DRY_RUN=false에서만"; else
      confirm "maas-api Pod를 재시작합니까?"
      oc rollout restart deploy/maas-api -n "$API_NS"
      oc rollout status deploy/maas-api -n "$API_NS" --timeout=180s
      expect "M06 재시작 후" 200 "$(curl -sS --cacert "$MAAS_CA_FILE" -o /dev/null -w '%{http_code}' -K <(bearer "$KEY_A") "https://${MAAS_HOST}/maas-api/v1/models" || true)"
    fi
    step "M07 Authorino x509 오류(1시간)"
    N=$(oc logs deploy/authorino -n kuadrant-system --since=1h | grep -ic x509 || true)
    [[ "$N" == 0 ]] && ok "x509 오류 없음" || warn "x509 오류 ${N}건"
    ;;

  evidence)
    D="$EVIDENCE_DIR/maas"; mkdir -p "$D"
    oc get kuadrant,authorino,limitador -n kuadrant-system
    oc get pod -n "$API_NS" | grep -E 'maas-postgresql|maas-api|maas-controller|llmisvc-controller-manager' || true
    oc get gateway maas-default-gateway -n openshift-ingress -o yaml >"$D/maas-gateway.yaml"
    oc get llminferenceservice,maasmodelrefs.maas.opendatahub.io -n "$MODEL_NS" -o yaml >"$D/model-test.yaml" 2>/dev/null || true
    oc get maassubscriptions.maas.opendatahub.io,maasauthpolicies.maas.opendatahub.io -n models-as-a-service -o yaml >"$D/maas-policies.yaml" 2>/dev/null || true
    oc get authpolicy,tokenratelimitpolicy -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,ENFORCED:'.status.conditions[?(@.type=="Enforced")].status' | tee "$D/policies.txt"
    # DB 덤프를 먼저 받는다(아래 조회는 스키마 버전에 따라 실패할 수 있음).
    F="$(backup_dir maas)/maas-db-$(date +%F-%H%M).sql"
    ( umask 077; oc exec -n "$MAAS_DB_NS" deploy/maas-postgresql -- pg_dump -d maas >"$F" ) && [[ -s "$F" ]] && ok "DB 덤프: $F" || warn "DB 덤프 실패: $F"
    oc exec -n "$MAAS_DB_NS" deploy/maas-postgresql -- psql -d maas -c \
      "select name, username, status, subscription, created_at, expires_at from api_keys order by created_at desc limit 10;" >"$D/api-keys.txt" 2>&1 \
      && cat "$D/api-keys.txt" || warn "api_keys 조회 실패(컬럼 확인): $D/api-keys.txt"
    ok "증적: $D"
    ;;

  cleanup)
    [[ -f "$UKC" ]] && { oc logout --kubeconfig="$UKC" || true; rm -f "$UKC"; }
    rm -f "$KEYS_FILE"; ok "kubeconfig·KEYS_FILE 삭제"
    log "테스트 리소스(Group ${MAAS_TEST_GROUP}, MaaSSubscription maas-test, MaaSAuthPolicy model-test-access, API key) 유지·삭제는 담당자와 결정"
    ;;
  *) die "사용: $0 db|user|prepare|key|auth|stability|evidence|cleanup" ;;
esac
