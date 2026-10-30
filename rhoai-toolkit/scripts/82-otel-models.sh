#!/usr/bin/env bash
# 모델별 OpenTelemetry 적용(지정 모델만): Python 자동 주입 annotation + OTEL env + vLLM native tracing 인자
#   사용: bash scripts/82-otel-models.sh <prod|test> plan       원복점 저장·patch 생성·서버 dry-run(클러스터 변경 없음)
#         DRY_RUN=false bash scripts/82-otel-models.sh <prod|test> apply   DRYRUN-OK 대상에만 적용(대상별 rolling update 1회)
#         bash scripts/82-otel-models.sh <prod|test> verify     모든 replica: Ready·init container·OTEL env·SDK import
#         DRY_RUN=false bash scripts/82-otel-models.sh <prod|test> rollback [모델..]   원복 patch(test op로 변경 없을 때만)
#   대상: prod = PROD_NS의 OTEL_MODELS(ISVC)·OTEL_LLM_MODELS(LLMI) / test = MODEL_NS의 OTEL_TEST_MODELS·OTEL_TEST_LLM_MODELS
#   적용 중 새 Pod가 GPU 부족으로 Pending이면 같은 모델의 이전 Pod를 정리해 GPU를 확보한다(해당 모델 일시 중단, 서비스 공지 대상).
#   OTel 적용 후 대상 모델 env를 바꾸지 않는다(원복 patch의 test op가 실패한다).
source "$(dirname "$0")/lib/common.sh"
init python3
SCOPE=${1:-}; CMD=${2:-}
[[ -n "$CMD" ]] || die "사용: $0 <prod|test> <plan|apply|verify|rollback> [모델..]"
shift 2
case "$SCOPE" in
  prod) NS=$PROD_NS; ISVC=$OTEL_MODELS; LLMI=$OTEL_LLM_MODELS ;;
  test) NS=$MODEL_NS; ISVC=$OTEL_TEST_MODELS; LLMI=$OTEL_TEST_LLM_MODELS ;;
  *) die "사용: $0 <prod|test> <plan|apply|verify|rollback>" ;;
esac
[[ "$ISVC$LLMI" != *"<"* ]] || die "config/env.sh의 OTel 대상 모델 목록에 자리표시자(<...>)가 남아 있습니다."
TARGETS=$(otel_targets "$ISVC" "$LLMI")
if (($# > 0)); then TARGETS=$(for t in $TARGETS; do for m in "$@"; do if [[ "${t#*:}" == "$m" ]]; then printf '%s ' "$t"; fi; done; done); fi
[[ -n "${TARGETS// /}" ]] || { log "$SCOPE 대상 모델 없음: 건너뜁니다."; exit 0; }
log "$SCOPE 대상($NS): $TARGETS"
M="$WORK_ROOT/manifests/otel"; W="$WORK_ROOT/otel"; B=$(backup_dir maas/otel)
mkdir -p "$M" "$W"; chmod 700 "$W"
R="$EVIDENCE_DIR/otel-$SCOPE-result.txt"
umask 077   # patch에는 CR env 전체가 들어간다

# 모델 Pod를 만드는 Deployment(ReplicaSet owner)
model_deploys() { oc get rs -n "$NS" -l "$(model_selector "$1" "$2")" -o json | jq -r '[.items[].metadata.ownerReferences[]? | select(.kind=="Deployment") | .name] | unique[]'; }
# wait_rollout <kind> <model>: 새 revision rollout 완료까지 기다린다(모델 로딩 포함, 기본 30분)
wait_rollout() {
  local d ds; ds=$(model_deploys "$1" "$2")
  [[ -n "$ds" ]] || { warn "$1/$2 Deployment를 찾지 못해 rollout 대기를 생략합니다."; return 0; }
  for d in $ds; do oc rollout status "deploy/$d" -n "$NS" --timeout="${OTEL_ROLLOUT_TIMEOUT:-1800}s" || return 1; done
}

case "$CMD" in
  plan)
    oc explain inferenceservice.spec.predictor.annotations >/dev/null 2>&1 || warn "ISVC predictor.annotations 스키마 없음"
    oc explain llminferenceservice.spec.annotations >/dev/null 2>&1 || warn "LLMI spec.annotations 스키마 없음(LLMI는 대상에서 제외 필요)"
    for t in $TARGETS; do
      k=${t%%:*}; m=${t#*:}; id=$k-$NS-$m; pf=$M/$id.patch.json; rf=$M/$id.rollback.json
      step "$id"
      # 적용 patch(pf)는 이번 plan이 성공할 때만 남긴다. 원복 patch(rf)는 새로 성공한 plan으로만 교체한다(이미 적용한 모델의 원복점 보존).
      save_once "$B/$id.before-otel.json" oc get "$k" "$m" -n "$NS" -o json
      [[ -s "$B/$id.before-otel.json" ]] || { warn "BACKUP-FAIL $id(모델 없음)"; rm -f "$pf"; continue; }
      p=$(oc get pod -n "$NS" -l "$(model_selector "$k" "$m")" -o json | jq -er '[.items[] | select(any(.status.conditions[]?; .type=="Ready" and .status=="True"))][0].metadata.name') \
        || { warn "NO-READY-POD $id(Ready Pod가 있어야 실제 env·args를 확인할 수 있음)"; rm -f "$pf"; continue; }
      oc get pod "$p" -n "$NS" -o json >"$W/$id.pod.json"
      if ! python3 "$TOOLKIT_ROOT/scripts/lib/otel_patch.py" "$k" "$B/$id.before-otel.json" "$W/$id.pod.json" "$PROD_OTLP_BASE" \
           "$PROD_NS/$INSTRUMENTATION_NAME" "vllm-$m" "$OTEL_SAMPLE_RATIO" "$pf.new" "$rf.new"; then
        warn "PLAN-FAIL $id$([[ -s "$rf" ]] && echo "(이미 적용된 모델이면 정상, 기존 원복 patch 유지: $rf)")"
        rm -f "$pf" "$pf.new" "$rf.new"; continue
      fi
      if oc patch "$k" "$m" -n "$NS" --type=json --patch-file="$pf.new" --dry-run=server -o json >"$W/$id.dryrun.json" && otel_verify "$k" "$W/$id.dryrun.json"; then
        mv -f "$pf.new" "$pf"; mv -f "$rf.new" "$rf"
        ok "DRYRUN-OK $id"; jq -c '.[] | {op, path}' "$pf"
      else
        warn "DRYRUN-FAIL $id(거부 또는 필드 미반영) → 적용 대상에서 제외"; rm -f "$pf" "$pf.new" "$rf.new"
      fi
    done
    ls -1 "$M"/*-"$NS"-*.patch.json 2>/dev/null | sed 's/^/  적용 대상 patch: /' || warn "적용할 patch가 없습니다."
    ;;

  apply)
    : >"$R"
    for t in $TARGETS; do
      k=${t%%:*}; m=${t#*:}; id=$k-$NS-$m; pf=$M/$id.patch.json
      if [[ ! -s "$pf" ]]; then echo "SKIP $k/$m(plan 결과 없음)" | tee -a "$R"; continue; fi
      if is_dry_run; then
        oc patch "$k" "$m" -n "$NS" --type=json --patch-file="$pf" --dry-run=server -o name >/dev/null && ok "[dry-run] $k/$m" || warn "[dry-run] 실패 $k/$m"
        continue
      fi
      confirm "$NS $k/$m 에 OTel을 적용합니까?(rolling update 1회)"
      if ! oc patch "$k" "$m" -n "$NS" --type=json --patch-file="$pf" -o name; then echo "FAIL $k/$m" | tee -a "$R"; continue; fi
      # 모델마다 GPU 확보·rollout 완료를 확인한 뒤 다음 모델로 넘어간다(동시 rolling update 방지).
      gpu_resolve "$NS"
      if wait_rollout "$k" "$m"; then echo "OK   $k/$m" | tee -a "$R"; else echo "NOT-READY $k/$m(rollout 미완료)" | tee -a "$R"; fi
    done
    is_dry_run || { oc get pod -n "$NS" -o wide; cat "$R"; }
    ;;

  verify)
    : >"$R.verify"
    for t in $TARGETS; do
      k=${t%%:*}; m=${t#*:}
      if [[ "$k" == isvc ]]; then c=kserve-container; else c=main; fi
      step "$k/$m"
      # 이전 revision Pod가 섞이지 않도록 rollout 완료 후 종료 중이 아닌 Pod만 확인한다.
      wait_rollout "$k" "$m" || { echo "NOT-READY $k/$m(rollout 미완료)" | tee -a "$R.verify"; continue; }
      pods=$(oc get pod -n "$NS" -l "$(model_selector "$k" "$m")" -o json | jq -r '.items[] | select(.metadata.deletionTimestamp == null) | "pod/" + .metadata.name')
      [[ -n "$pods" ]] || { echo "NO-POD $k/$m" | tee -a "$R.verify"; continue; }
      for p in $pods; do
        oc wait -n "$NS" --for=condition=Ready "$p" --timeout=600s >/dev/null 2>&1 || { echo "NOT-READY $k/$m $p" | tee -a "$R.verify"; continue; }
        (oc get -n "$NS" "$p" -o json 2>/dev/null || echo '{}') | jq -c --arg c "$c" '{pod:.metadata.name, init:[.spec.initContainers[]?|.name], otel:[.spec.containers[]?|select(.name==$c)|.env[]?|select(.name|test("^OTEL_SERVICE_NAME$|^OTEL_EXPORTER_OTLP_TRACES_ENDPOINT$|^PYTHONPATH$"))|.name]}'
        if oc exec -n "$NS" "$p" -c "$c" -- python3 -c 'import importlib.metadata as m; print("vllm",m.version("vllm"),"otel-sdk",m.version("opentelemetry-sdk")); from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter; print("HTTP exporter OK")'; then
          echo "OK $k/$m $p" >>"$R.verify"
        else
          echo "IMPORT-FAIL $k/$m $p" | tee -a "$R.verify"
        fi
      done
    done
    grep -qvE '^OK ' "$R.verify" && warn "확인 실패 항목이 있습니다: $R.verify" || ok "모든 replica 주입 확인"
    ;;

  rollback)
    for t in $TARGETS; do
      k=${t%%:*}; m=${t#*:}; rf=$M/$k-$NS-$m.rollback.json
      [[ -s "$rf" ]] || { warn "원복 patch 없음: $rf"; continue; }
      if is_dry_run; then
        oc patch "$k" "$m" -n "$NS" --type=json --patch-file="$rf" --dry-run=server -o name >/dev/null && ok "[dry-run] 원복 가능 $k/$m" || warn "[dry-run] 원복 불가 $k/$m(적용 후 값이 바뀜 → 백업 $B/$k-$NS-$m.before-otel.json 대조)"
      else
        confirm "$NS $k/$m 의 OTel 적용을 원복합니까?(rolling update 1회)"
        oc patch "$k" "$m" -n "$NS" --type=json --patch-file="$rf" -o name || warn "원복 실패 $k/$m"
      fi
    done
    is_dry_run || gpu_resolve "$NS"
    ;;
  *) die "사용: $0 <prod|test> <plan|apply|verify|rollback>" ;;
esac
