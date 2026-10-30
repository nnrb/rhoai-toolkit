#!/usr/bin/env bash
# 추가 필요 이미지 식별(조회 전용, 클러스터 변경 없음)
#   클러스터가 참조하는 이미지를 IDMS/ITMS 규칙으로 미러 경로로 바꾼 뒤, 내부 레지스트리에 실제로 있는지 oc image info로 확인한다.
#   수집 대상
#     ① RHOAI·의존 Operator CSV의 relatedImages, RELATED_IMAGE_* env, Operator 이미지
#     ② redhat-ods-applications ImageStream(Workbench·Pipeline 런타임)
#     ③ 서빙 런타임 Template, LLMInferenceServiceConfig, ServingRuntime, ClusterTrainingRuntime의 image 필드
#     ④ 모델 카탈로그 ConfigMap의 oci:// URI(Model Catalog 모델)
#     ⑤ 최근 이미지 pull 실패 이벤트
#     ⑥ EXTRA_FILE(직접 적은 후보 목록, 한 줄에 하나)
#   결과: out/image-gap-<시각>/ images-all.txt, result.tsv, images-missing.txt, additionalImages-missing.yaml
#   사용: ./05-image-gap-check.sh
#         ONLY_EXTRA=true EXTRA_FILE=../mirror/runtime-images.txt ./05-image-gap-check.sh   # 스크립트 실행용 이미지만
#         EXTRA_FILE=candidates.txt REGISTRY_CONFIG=~/.docker/config.json PARALLEL=8 ./05-image-gap-check.sh
#   판정: PRESENT(미러에 있음) / MISSING(미러 경로에 없음) / NO-MAPPING(IDMS·ITMS 규칙 없음 → 폐쇄망에서 pull 불가)
source "$(dirname "$0")/lib/common.sh"
[[ -f "$ENV_FILE" ]] && load_env
require oc jq
AI_NS=${AI_NS:-redhat-ods-applications}
PARALLEL=${PARALLEL:-8}
CSV_PATTERN=${CSV_PATTERN:-'^(rhods-operator|rhcl-operator|authorino-operator|limitador-operator|dns-operator|leader-worker-set|kueue-operator|jobset-operator|job-set|tempo-operator|opentelemetry-operator|cluster-observability-operator|servicemeshoperator3|cert-manager-operator)'}
OUT="${GAP_DIR:-${OUT_DIR:-$BUNDLE_DIR/out}/image-gap-$(date +%Y%m%d-%H%M%S)}"   # GAP_DIR: 결과 디렉터리를 정확히 지정(bc-toolkit.sh images)
mkdir -p "$OUT"

step "1. 참조 이미지 수집"
{
  if [[ "${ONLY_EXTRA:-false}" != "true" ]]; then
  oc get csv -A -o json | jq -r --arg re "$CSV_PATTERN" '
    .items[] | select(.metadata.name | test($re)) |
    ((.spec.relatedImages // [])[].image),
    (.spec.install.spec.deployments[]?.spec.template.spec.containers[]? | .image, (.env[]? | select(.name | startswith("RELATED_IMAGE_")) | .value))'
  oc get imagestream -n "$AI_NS" -o json | jq -r '.items[].spec.tags[]? | select(.from.kind == "DockerImage") | .from.name'
  for r in templates.template.openshift.io llminferenceserviceconfigs.serving.kserve.io servingruntimes.serving.kserve.io; do
    oc get "$r" -n "$AI_NS" -o json 2>/dev/null | jq -r '.. | objects | .image? // empty | strings' || true
  done
  for r in clustertrainingruntimes.trainer.kubeflow.org clusterservingruntimes.serving.kserve.io; do
    oc get "$r" -o json 2>/dev/null | jq -r '.. | objects | .image? // empty | strings' || true
  done
  for ns in "$AI_NS" rhoai-model-registries; do
    oc get cm -n "$ns" -o json 2>/dev/null | jq -r '.items[].data // {} | .[]' | grep -oE 'oci://[A-Za-z0-9._/:@-]+' | sed 's#^oci://##' || true
  done
  oc get events -A -o json | jq -r '.items[] | select(.reason == "Failed" or .reason == "ErrImagePull") | .message' \
    | grep -oE 'image "[^"]+"' | sed -E 's/^image "//; s/"$//' || true
  fi
  # EXTRA_FILE: 한 줄에 이미지 하나(뒤의 공백 이후는 무시, # 주석 무시). ONLY_EXTRA=true면 이 목록만 확인한다.
  if [[ -n "${EXTRA_FILE:-}" ]]; then { grep -vE '^\s*(#|$)' "$EXTRA_FILE" || true; } | sed -E 's/^\s*-?\s*(name:)?\s*//; s/[[:space:]].*$//'; fi
} | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' \
  | { grep -vE '^$|[{}$]|image-registry\.openshift-image-registry\.svc' || true; } \
  | sort -u > "$OUT/images-all.txt"
info "수집 이미지 $(wc -l < "$OUT/images-all.txt")개 → $OUT/images-all.txt"

step "2. 미러 규칙(IDMS: digest, ITMS: tag)"
{
  oc get imagedigestmirrorset -o json | jq -r '.items[].spec.imageDigestMirrors[]? | .source as $s | (.mirrors // [])[] | "D\t\($s)\t\(.)"'
  oc get imagetagmirrorset -o json | jq -r '.items[].spec.imageTagMirrors[]? | .source as $s | (.mirrors // [])[] | "T\t\($s)\t\(.)"'
} > "$OUT/mirror-rules.tsv"
info "규칙 $(wc -l < "$OUT/mirror-rules.tsv")개"
MIRROR_HOSTS=$(cut -f3 "$OUT/mirror-rules.tsv" | cut -d/ -f1 | sort -u | tr '\n' ' ')
info "미러 레지스트리: $MIRROR_HOSTS"

step "3. 내부 레지스트리 확인(병렬 $PARALLEL)"
check_one() {
  local img=$1 repo ref kind cands="" src mirror k c
  if [[ "$img" == *@* ]]; then repo=${img%%@*}; ref="@${img#*@}"; kind=D
  else
    if [[ "${img##*/}" == *:* ]]; then repo=${img%:*}; ref=":${img##*:}"; else repo=$img; ref=":latest"; fi
    kind=T
  fi
  # 이미 미러 레지스트리 경로면 그대로 확인
  for h in $MIRROR_HOSTS; do [[ "${repo%%/*}" == "$h" ]] && cands="$img"; done
  if [[ -z "$cands" ]]; then
    # CRI-O와 같이 가장 긴(구체적인) source 하나의 mirror만 쓴다(짧은 source는 무시)
    local best=-1
    while IFS=$'\t' read -r k src mirror; do
      [[ "$k" == "$kind" ]] || continue
      (( best >= 0 && ${#src} < best )) && break
      if [[ "$repo" == "$src" || "$repo" == "$src"/* ]]; then cands="$cands ${mirror}${repo#"$src"}${ref}"; best=${#src}; fi
    done < <(awk -F'\t' '{ print length($2) "\t" $0 }' "$RULES" | sort -t$'\t' -k1,1nr | cut -f2-)
  fi
  if [[ -z "${cands// /}" ]]; then printf 'NO-MAPPING\t%s\t-\n' "$img"; return 0; fi
  local err=""
  for c in $cands; do
    if err=$(oc image info --filter-by-os=linux/amd64 ${REGISTRY_CONFIG:+-a "$REGISTRY_CONFIG"} ${INSECURE:+--insecure=true} "$c" 2>&1 >/dev/null); then
      printf 'PRESENT\t%s\t%s\n' "$img" "$c"; return 0
    fi
  done
  # 인증·인증서·연결 오류는 미반입과 구분한다(ERROR: 확인 실패).
  case "$err" in
    *nauthorized*|*x509*|*certificate*|*"no such host"*|*"connection refused"*|*timeout*)
      printf 'ERROR\t%s\t%s\n' "$img" "$(tail -1 <<<"$err" | tr '\t' ' ' | cut -c1-200)"; return 0 ;;
  esac
  printf 'MISSING\t%s\t%s\n' "$img" "$(echo $cands | tr ' ' ',')"
}
export -f check_one
export RULES="$OUT/mirror-rules.tsv" MIRROR_HOSTS REGISTRY_CONFIG="${REGISTRY_CONFIG:-}" INSECURE="${INSECURE:-}"
xargs -a "$OUT/images-all.txt" -P "$PARALLEL" -I{} bash -c 'check_one "$1"' _ {} | sort > "$OUT/result.tsv"

step "4. 결과"
awk -F'\t' '{ n[$1]++ } END { for (k in n) printf "  %-10s %d\n", k, n[k] }' "$OUT/result.tsv"
awk -F'\t' '$1 != "PRESENT" { print $2 }' "$OUT/result.tsv" > "$OUT/images-missing.txt"
{
  echo "# 05-image-gap-check.sh 결과 $(date '+%F %T'). imageset-02의 [C] 위치(additionalImages)에 붙인다."
  echo "# 태그(:tag) 이미지는 인터넷 구간에서 skopeo inspect로 digest를 확인해 @sha256 형식으로 바꾸는 것을 권장한다."
  awk -F'\t' '$1 != "PRESENT" { printf "    - name: %s   # %s\n", $2, $1 }' "$OUT/result.tsv"
} > "$OUT/additionalImages-missing.yaml"
if [[ -s "$OUT/images-missing.txt" ]]; then
  warn "미러에 없는 이미지 $(wc -l < "$OUT/images-missing.txt")개 → $OUT/additionalImages-missing.yaml"
  head -20 "$OUT/images-missing.txt" | sed 's/^/    /'
else
  ok "모든 참조 이미지가 내부 레지스트리에 있음"
fi
info "상세: $OUT/result.tsv (판정, 원본, 확인한 미러 경로)"
summary
