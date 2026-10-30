#!/usr/bin/env bash
# llm-d 검증(검증 모델 MODEL_NS/MODEL_NAME, 운영 모델 제외)
#   하위 명령
#     check        배포 전제: llmisvc 컨트롤러, namespace label, 기본 LLMInferenceServiceConfig 이미지·미러, GPU 여유
#     s3conn       모델 파일 S3 Connection(S3_CONNECTION)이 없으면 값을 입력받아 생성(자격증명은 화면·파일에 남기지 않음)
#     model        Dashboard 배포(llm-d, Publish as MaaS) 후 상태: LLMI Ready, vLLM 기동 로그, MaaSModelRef, HTTPRoute
#     scale        replica 2 + llm-d scheduler(기본 dry-run). GPU 부족 Pending이면 이전 Pod 정리
#     route        T1 인증 유지 / T2 서로 다른 요청 20건 → 두 Pod 모두 처리 / T3 같은 system prompt 10건 → prefix cache
#     load         T4 동시 30건 → 두 Pod 모두 처리 중
#     fault        T5 vLLM Pod 삭제 중 연속 호출 / T6 scheduler Pod 삭제 직후 호출(05:00 이후 시작 금지, 담당자 승인 시만)
#   KEYS_FILE의 KEY_A를 쓴다(75-maas-test.sh key).
source "$(dirname "$0")/lib/common.sh"
init curl
CMD=${1:-}
MODEL_URL="https://${MAAS_HOSTNAME}/${MODEL_NS}/${MODEL_NAME}"
PIDS=""; RESP=$(mktemp)
trap 'for p in $PIDS; do kill "$p" 2>/dev/null || true; done; rm -f "$RESP"' EXIT
load_key() { [[ -s "$KEYS_FILE" ]] || die "$KEYS_FILE 이 없습니다(75-maas-test.sh key)."; source "$KEYS_FILE"; }
chat() { # chat <내용> <max_tokens> [system]
  local body
  if [[ -n "${3:-}" ]]; then
    body=$(jq -cn --arg m "$MODEL_NAME" --arg s "$3" --arg u "$1" --argjson n "$2" '{model:$m,messages:[{role:"system",content:$s},{role:"user",content:$u}],max_tokens:$n}')
  else
    body=$(jq -cn --arg m "$MODEL_NAME" --arg u "$1" --argjson n "$2" '{model:$m,messages:[{role:"user",content:$u}],max_tokens:$n}')
  fi
  curl -sS --cacert "$MAAS_CA_FILE" -o "$RESP" -w '%{http_code}' -m 120 -K <(bearer "$KEY_A") -H 'Content-Type: application/json' \
    -d "$body" "${MODEL_URL}/v1/chat/completions" || true
}
vllm_pods() { oc get pod -n "$MODEL_NS" -l "app.kubernetes.io/name=${MODEL_NAME},kserve.io/component=workload" -o name | sed 's#pod/##'; }
port_forward() { # 두 vLLM Pod를 18001·18002로 연결
  local i=0 p
  for p in $(vllm_pods | head -2); do
    i=$((i + 1)); oc port-forward -n "$MODEL_NS" "pod/$p" "1800$i:8000" >/dev/null 2>&1 & PIDS="$PIDS $!"
    log "port-forward $p → 1800$i"
  done
  ((i == 2)) || die "vLLM Pod가 2개가 아닙니다(scale 먼저)."
  sleep 3
}
metrics() { # metrics <정규식>
  local p
  for p in 18001 18002; do echo "  == $p"; curl -sk "https://localhost:$p/metrics" | grep -E "^vllm:($1)" | sed 's/^/     /' || true; done
}

case "$CMD" in
  check)
    step "llm-d 배포 전제"
    oc get pod -n "$AI_NS" | grep llmisvc-controller-manager || warn "llmisvc-controller-manager 없음"
    oc get ns "$MODEL_NS" -L "$GATEWAY_ACCESS_LABEL" || warn "namespace $MODEL_NS 없음(Dashboard에서 프로젝트 생성)"
    oc get isvc,llmisvc -n "$MODEL_NS" 2>/dev/null || true
    oc get llminferenceserviceconfig -n "$AI_NS" -L opendatahub.io/config-type 2>/dev/null || true
    IMG=$( (oc get llminferenceserviceconfig -n "$AI_NS" -o json 2>/dev/null || echo '{"items":[]}') | jq -r '[.items[] | select(.metadata.name | test("llm-template-nvidia-cuda")) | .spec.template.containers[0].image][0] // empty')
    log "vLLM 이미지: ${IMG:-확인 불가}"
    REPO=${IMG%%@*}
    [[ -n "$REPO" ]] && { oc get imagedigestmirrorset -o json | jq -e --arg r "$REPO" '[.items[].spec.imageDigestMirrors[]?.source | select(. as $s | $r | startswith($s))] | length > 0' >/dev/null && ok "vLLM 이미지 미러 규칙 있음" || warn "vLLM 이미지($REPO) 미러 규칙 없음"; }
    step "GPU 여유"
    for n in $(oc get nodes -l nvidia.com/gpu.present=true -o name); do echo "  == $n"; oc describe "$n" | grep -A8 'Allocated resources' | grep nvidia.com | sed 's/^/    /' || true; done
    [[ -z "$(gpu_pending)" ]] && ok "GPU 부족 Pending 없음" || { warn "GPU 부족 Pending:"; gpu_pending; }
    log "필요 GPU: 검증 모델 1 + scale 시 1 + OTel 적용 rolling update 시 일시 1. 없으면 llm-d 검증은 미실시로 기록(운영 모델은 중지하지 않음)"
    ;;

  s3conn)
    step "S3 Connection $MODEL_NS/$S3_CONNECTION"
    if oc get secret "$S3_CONNECTION" -n "$MODEL_NS" >/dev/null 2>&1; then
      ok "이미 있음 — 생성하지 않음"
      oc get secret "$S3_CONNECTION" -n "$MODEL_NS" -o json | jq -c '{type: .metadata.annotations["opendatahub.io/connection-type-ref"], keys: (.data|keys)}'
    elif is_dry_run; then
      log "[dry-run] 없음 → DRY_RUN=false로 실행하면 값을 입력받아 만듭니다."
    else
      read -r -p "S3 endpoint(https://...): " EP </dev/tty
      read -r -p "S3 bucket: " BK </dev/tty
      read -r -s -p "S3 access key: " AK </dev/tty; echo
      read -r -s -p "S3 secret key: " SK </dev/tty; echo
      [[ -n "$EP" && -n "$BK" && -n "$AK" && -n "$SK" ]] || die "빈 값이 있습니다."
      put_secret "$S3_CONNECTION" "$MODEL_NS" "AWS_ACCESS_KEY_ID=$AK" "AWS_SECRET_ACCESS_KEY=$SK" "AWS_S3_ENDPOINT=$EP" "AWS_S3_BUCKET=$BK"
      unset AK SK
      oc label secret "$S3_CONNECTION" -n "$MODEL_NS" opendatahub.io/dashboard=true --overwrite
      oc annotate secret "$S3_CONNECTION" -n "$MODEL_NS" opendatahub.io/connection-type-ref=s3 "openshift.io/display-name=$S3_CONNECTION" --overwrite
    fi
    ;;

  model)
    DRY_RUN=false   # 조회 전용 대기이므로 dry-run과 관계없이 실제로 기다린다
    step "검증 모델 $MODEL_NS/$MODEL_NAME"
    wait_for "LLMInferenceService Ready" 1200 bash -c "oc get llminferenceservice '$MODEL_NAME' -n '$MODEL_NS' -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -qx True" \
      || warn "LLMI가 Ready가 아닙니다: oc get llminferenceservice $MODEL_NAME -n $MODEL_NS -o yaml"
    oc get llminferenceservice "$MODEL_NAME" -n "$MODEL_NS" -o jsonpath='{"containers="}{.spec.template.containers[*].name}{"\n"}' 2>/dev/null || true
    oc logs -n "$MODEL_NS" "deploy/${MODEL_NAME}-kserve" -c main --tail=200 2>/dev/null | grep -E 'Starting vLLM API server|Application startup complete|compute capability' || warn "vLLM 기동 로그 확인 필요"
    oc get maasmodelrefs.maas.opendatahub.io -n "$MODEL_NS" 2>/dev/null || warn "MaaSModelRef 없음(Publish as MaaS 확인)"
    oc get httproute -n "$MODEL_NS" -o json | jq -c '.items[] | {name: .metadata.name, parents: [.status.parents[]?.controllerName]}'
    [[ -z "$(gpu_pending)" ]] && ok "GPU 부족 Pending 없음" || gpu_pending
    ;;

  scale)
    step "replica 2 + llm-d scheduler"
    save_once "$(backup_dir maas)/llmisvc-$MODEL_NAME.before-scale.json" oc get llminferenceservice "$MODEL_NAME" -n "$MODEL_NS" -o json
    log "VLLM_ADDITIONAL_ARGS: $(oc get llminferenceservice "$MODEL_NAME" -n "$MODEL_NS" -o json | jq -r '.spec.template.containers[] | select(.name=="main") | .env[]? | select(.name=="VLLM_ADDITIONAL_ARGS") | .value')"
    log "같은 물리 GPU에 2개를 올리는(time-slicing) 경우 배포 시 --gpu-memory-utilization=0.45여야 한다(여기서 env를 바꾸지 않음)."
    confirm "$MODEL_NAME 을 replica 2 + scheduler로 바꿉니까?"
    k_patch llminferenceservice "$MODEL_NAME" "$MODEL_NS" merge '{"spec":{"replicas":2,"router":{"scheduler":{}}}}'
    if ! is_dry_run; then
      gpu_resolve "$MODEL_NS"
      wait_for "LLMI Ready" 1200 bash -c "oc get llminferenceservice '$MODEL_NAME' -n '$MODEL_NS' -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -qx True" || true
      oc get llminferenceservice "$MODEL_NAME" -n "$MODEL_NS" -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'
      oc get inferencepools.inference.networking.x-k8s.io -n "$MODEL_NS" 2>/dev/null || true
      oc get pod -n "$MODEL_NS" -o wide | grep "$MODEL_NAME" || true
    fi
    ;;

  route)
    load_key
    step "T1 인증 유지"
    C=$(curl -sS --cacert "$MAAS_CA_FILE" -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
      -d "{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" "${MODEL_URL}/v1/chat/completions" || true)
    [[ "$C" == 401 ]] && ok "key 없음 401" || warn "key 없음 → $C"
    C=$(chat "hi" 20); [[ "$C" == 200 ]] && ok "KEY_A 200" || warn "KEY_A → $C"
    oc get authpolicy,tokenratelimitpolicy -n "$MODEL_NS" -o custom-columns=NAME:.metadata.name,ENFORCED:'.status.conditions[?(@.type=="Enforced")].status'
    port_forward
    step "T2 서로 다른 질문 20건 → 두 Pod 모두 증가"
    metrics 'request_success_total'
    codes=""; for i in $(seq 1 20); do codes="$codes $(chat "숫자 $i 에 대해 한 문장" 30)"; done; log "응답:$codes"
    metrics 'request_success_total'
    step "T3 같은 system prompt 10건 → 한 Pod로 모이고 prefix_cache_hits 증가"
    SYS=$(printf '당신은 사내 규정 안내 도우미입니다. %.0s' $(seq 1 120))
    metrics 'prefix_cache_hits|prefix_cache_queries|request_success_total'
    codes=""; for i in $(seq 1 10); do codes="$codes $(chat "질문 $i" 20 "$SYS")"; done; log "응답:$codes"
    metrics 'prefix_cache_hits|prefix_cache_queries|request_success_total'
    ;;

  load)
    load_key
    port_forward
    step "T4 동시 30건 → 두 Pod 모두 num_requests_running > 0"
    sleep 65
    CP=""; LD=$(mktemp -d)
    for i in $(seq 1 30); do ( chat "긴 이야기를 써줘 $i" 400 >"$LD/$i" ) & CP="$CP $!"; done
    sleep 3; metrics 'num_requests_running|num_requests_waiting'
    wait $CP || true
    codes=$(for f in "$LD"/*; do cat "$f"; echo; done | sort | uniq -c | awk '{printf "%s:%s건 ", $2, $1}'); rm -rf "$LD"
    [[ "$codes" =~ (^|[[:space:]])(5[0-9][0-9]|000): ]] && warn "동시 요청 응답: $codes" || ok "동시 요청 완료: $codes"
    ;;

  fault)
    load_key
    is_dry_run && { log "[dry-run] T5·T6 Pod 삭제 시험은 DRY_RUN=false에서만 수행합니다."; exit 0; }
    H=$((10#$(date +%H)))
    if (( H >= 5 && H < 19 )); then die "05:00~19:00에는 장애 시험을 시작하지 않습니다(작업 시간대 기준)."; fi
    confirm "검증 모델 Pod를 삭제하는 장애 시험(T5·T6)을 합니까? 담당자 승인 필요"
    P1=$(vllm_pods | head -1)
    step "T5 vLLM Pod($P1) 삭제 중 2초 간격 15건"
    oc delete pod -n "$MODEL_NS" "$P1" --wait=false
    codes=""; for i in $(seq 1 15); do codes="$codes $(chat "hi $i" 20)"; sleep 2; done; log "응답:$codes"
    oc get pod -n "$MODEL_NS" | grep "${MODEL_NAME}-kserve" || true
    step "T6 scheduler Pod 삭제 직후 1초 간격 10건"
    S=$(oc get pod -n "$MODEL_NS" -o name | grep "${MODEL_NAME}-kserve-router-scheduler" | head -1)
    [[ -n "$S" ]] && oc delete -n "$MODEL_NS" "$S" --wait=false
    codes=""; for i in $(seq 1 10); do codes="$codes $(chat "hi $i" 20)"; sleep 1; done; log "응답:$codes"
    oc logs -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=maas-default-gateway --since=2m --tail=200 | grep -iE 'ext_proc|inference|epp' | tail -20 || true
    ;;
  *) die "사용: $0 check|s3conn|model|scale|route|load|fault" ;;
esac
