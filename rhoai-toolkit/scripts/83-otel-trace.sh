#!/usr/bin/env bash
# 실제 추론 1건을 traceparent와 함께 호출하고 TRACE_ID를 남긴다(Console Observe → Traces에서 확인).
#   사용: bash scripts/83-otel-trace.sh maas   MaaS 공개 검증 모델(MODEL_NAME) — KEYS_FILE의 KEY_A 사용
#         bash scripts/83-otel-trace.sh url    그 외 모델 — endpoint URL·served model·key·CA를 실행 중에 입력(key는 화면·파일에 남기지 않음)
#   합격: tempo/<TEMPO_STACK>, tenant <TEMPO_TENANT>, service vllm-<모델>에서 같은 TRACE_ID의 HTTP span과 vLLM 추론 span
source "$(dirname "$0")/lib/common.sh"
init curl openssl
MODE=${1:-}
OUT="$EVIDENCE_DIR/otel-trace"; mkdir -p "$OUT"
REQ=$(mktemp); trap 'rm -f "$REQ"' EXIT
TRACE_ID=$(openssl rand -hex 16); PARENT=$(openssl rand -hex 8)

case "$MODE" in
  maas)
    [[ -s "$KEYS_FILE" ]] || die "$KEYS_FILE 이 없습니다(75-maas-test.sh key 먼저)."
    # shellcheck source=/dev/null
    source "$KEYS_FILE"
    URL="https://${MAAS_HOSTNAME}/${MODEL_NS}/${MODEL_NAME}"; MODEL=$MODEL_NAME; CA=$MAAS_CA_FILE; KEY=$KEY_A
    ;;
  url)
    read -r -p '검증할 모델 API base URL(…/v1 앞까지): ' URL </dev/tty
    read -r -p 'served model name: ' MODEL </dev/tty
    read -r -s -p '해당 endpoint 인증 key/token: ' KEY </dev/tty; echo
    read -r -p '서버 인증서 발급 CA PEM 파일 경로: ' CA </dev/tty
    ;;
  *) die "사용: $0 <maas|url>" ;;
esac
[[ -f "$CA" ]] || die "CA 파일이 없습니다: $CA"
jq -n --arg model "$MODEL" '{model:$model,messages:[{role:"user",content:"Reply with OK."}],max_tokens:16,stream:false}' >"$REQ"
CODE=$(curl -sS --cacert "$CA" -o "$OUT/$MODEL-response.json" -w '%{http_code}' \
  -K <(bearer "$KEY") -H 'Content-Type: application/json' \
  -H "traceparent: 00-${TRACE_ID}-${PARENT}-01" --data @"$REQ" "${URL}/v1/chat/completions" || true)
unset KEY KEY_A
echo "$(date '+%F %T') $MODEL TRACE_ID=$TRACE_ID HTTP=$CODE" | tee -a "$OUT/trace-ids.txt"
[[ "$CODE" == 200 ]] && ok "추론 200" || warn "추론 응답 ${CODE:-연결 실패}: $OUT/$MODEL-response.json"
sleep 15
ERR=$(collector_errors llm-otel-collector "$PROD_NS" 5m)
[[ "$ERR" == 0 ]] && ok "Collector 오류 없음" || warn "Collector 로그 오류: ${ERR}(oc logs deploy/llm-otel-collector -n $PROD_NS)"
log "Console: Observe → Traces / ${TEMPO_NS}/${TEMPO_STACK} / tenant ${TEMPO_TENANT} / service vllm-<모델> / TRACE_ID=$TRACE_ID"
