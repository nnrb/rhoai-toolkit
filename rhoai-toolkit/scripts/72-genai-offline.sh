#!/usr/bin/env bash
# Gen AI Playground 폐쇄망 보정: Llama Stack(3.4) / OGX(3.5) 서버가 HuggingFace에서 임베딩 모델을
# 내려받으려다 실패하는 문제를 막는다(RHOAIENG-50523, RHAIENG-1624). 모델은 이미지에 포함되어 있다.
#   대상: 모든 LlamaStackDistribution(3.4) 또는 OGXServer(3.5)
#   서버 Pod가 재시작된다. Playground 생성 후(인스턴스가 생긴 뒤) 실행한다.
source "$(dirname "$0")/lib/common.sh"
init

is_on "$FEATURE_GENAI" || { log "FEATURE_GENAI=false: 건너뜁니다."; exit 0; }

OFFLINE_ENV='[
  {"name":"SENTENCE_TRANSFORMERS_HOME","value":"/opt/app-root/src/.cache/huggingface/hub"},
  {"name":"HF_HUB_OFFLINE","value":"1"},
  {"name":"TRANSFORMERS_OFFLINE","value":"1"},
  {"name":"HF_DATASETS_OFFLINE","value":"1"}
]'

# patch_env <resource> <env 경로(점 구분)>
patch_env() {
  local res=$1 path=$2 items ns name cur merged
  items=$(oc get "$res" -A -o json 2>/dev/null | jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"' || true)
  [[ -n "$items" ]] || { log "$res 인스턴스가 없습니다. Playground를 만든 뒤 다시 실행하세요."; return 0; }
  while read -r ns name; do
    cur=$(oc get "$res" "$name" -n "$ns" -o json | jq -c --arg p "$path" 'getpath($p | split(".")) // []')
    merged=$(jq -c --argjson add "$OFFLINE_ENV" '[.[] | select(.name as $n | ($add | map(.name) | index($n)) | not)] + $add' <<<"$cur")
    if [[ "$(jq -S . <<<"$cur")" == "$(jq -S . <<<"$merged")" ]]; then ok "$ns/$name 이미 설정됨"; continue; fi
    backup "$res" "$name" "$ns"
    k_patch "$res" "$name" "$ns" merge "$(jq -cn --arg p "$path" --argjson v "$merged" 'setpath($p | split("."); $v)')"
  done <<<"$items"
}

RES=$( (oc api-resources -o name 2>/dev/null || true) | grep '^ogxservers\.' | head -n1 || true)
if [[ -n "$RES" ]]; then
  # 3.5 OGXServer의 env 경로는 스키마에서 찾는다.
  for p in spec.server.containerSpec.env spec.containerSpec.env spec.env; do
    if has_field ogxserver "$p"; then patch_env "$RES" "$p"; exit 0; fi
  done
  warn "OGXServer 스키마에서 env 경로를 찾지 못했습니다. oc explain ogxserver.spec --recursive 로 확인 후 수동 적용하세요."
elif has_crd llamastackdistributions.llamastack.io; then
  patch_env llamastackdistributions.llamastack.io spec.server.containerSpec.env
else
  log "Llama Stack / OGX CRD가 없습니다(DSC 컴포넌트 확인)."
fi
