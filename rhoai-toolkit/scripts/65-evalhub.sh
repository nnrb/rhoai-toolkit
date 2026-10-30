#!/usr/bin/env bash
# EvalHub(모델 평가, TP) — RHOAI-Toolkit demo/lmeval-demo/manifests/evalhub.yaml 기준(SQLite)
#   - RHOAI 3.4 Dashboard의 eval-hub-ui는 redhat-ods-applications의 EvalHub만 찾는다(docs/bugs/evalhub-dashboard-namespace-lookup.md).
#   - 평가 Job 이미지는 TrustyAI Operator(RHOAI CSV relatedImages). 추가 이미지 없음.
#   - 폐쇄망 주의: tokenizer·데이터셋을 HuggingFace에서 받지 않도록 평가 요청에 내부 S3·PVC 경로를 지정한다.
source "$(dirname "$0")/lib/common.sh"
init
is_on "$FEATURE_TRUSTYAI" && is_on "$FEATURE_EVALHUB" || { log "FEATURE_EVALHUB=false: 건너뜁니다."; exit 0; }

step "1. 전제 조건"
has_crd evalhubs.trustyai.opendatahub.io || { warn "EvalHub CRD 없음(RHOAI 3.4 이상, trustyai Managed 필요) — 건너뜁니다."; exit 0; }
EXIST=$(oc get evalhubs.trustyai.opendatahub.io -A -o name 2>/dev/null || true)
[[ -z "$EXIST" ]] || { ok "EvalHub 이미 있음: $(echo $EXIST) — 변경하지 않습니다."; exit 0; }
MLFLOW_URI=$(oc get mlflows.mlflow.opendatahub.io -A -o jsonpath='{.items[0].status.url}' 2>/dev/null || true)

step "2. EvalHub CR ($EVALHUB_NS)"
f="$EVIDENCE_DIR/evalhub.yaml"
{
  cat <<EOF
apiVersion: trustyai.opendatahub.io/v1alpha1
kind: EvalHub
metadata:
  name: evalhub
  namespace: ${EVALHUB_NS}
spec:
  replicas: 1
  database:
    type: sqlite
  providers:
    - lm-evaluation-harness
    - garak
    - guidellm
    - lighteval
EOF
  if [[ -n "$MLFLOW_URI" ]]; then printf '  env:\n    - name: MLFLOW_TRACKING_URI\n      value: "%s"\n' "$MLFLOW_URI"; fi
} >"$f"
confirm "EvalHub($EVALHUB_NS, SQLite)를 만듭니까?"
k_apply "$f"
if ! is_dry_run; then
  wait_for "EvalHub Deployment" 600 bash -c "oc get deploy -n '$EVALHUB_NS' -o name | grep -q evalhub" || true
  oc rollout restart deployment/rhods-dashboard -n "$AI_NS"   # eval-hub-ui가 새 EvalHub를 읽도록
fi
log "알려진 문제(RHOAI 3.4): Benchmark suite UI는 tokenizer 파라미터를 버린다 → 단일 benchmark 또는 SDK, lm_evaluation_harness + tokenizer 경로 지정"
