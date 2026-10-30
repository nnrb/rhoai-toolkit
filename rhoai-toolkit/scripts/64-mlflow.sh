#!/usr/bin/env bash
# MLflow 인스턴스(RHOAI-Toolkit lib/manifests/rhoai/mlflow-cr.yaml 기준: SQLite + PVC)
#   실험 추적·프롬프트 관리(promptManagement)·EvalHub 결과 저장에 쓴다. 이미지는 mlflowoperator(RHOAI CSV relatedImages).
#   이미 MLflow 인스턴스가 있으면 변경하지 않는다. PVC는 기본 StorageClass(BC: ontap-iscsi 기본 여부 00-preflight에서 확인).
source "$(dirname "$0")/lib/common.sh"
init
is_on "$FEATURE_MLFLOW" && is_on "$FEATURE_MLFLOW_INSTANCE" || { log "FEATURE_MLFLOW_INSTANCE=false: 건너뜁니다."; exit 0; }

step "1. 전제 조건"
CRD=$(oc get crd -o name 2>/dev/null | grep -E 'mlflows\.mlflow\.opendatahub\.io$' || true)
[[ -n "$CRD" ]] || { warn "MLflow CRD 없음 — 20-dsc.sh(mlflowoperator Managed) 이후 다시 실행"; exit 0; }
EXIST=$(oc get mlflows.mlflow.opendatahub.io -A -o name 2>/dev/null || true)
[[ -z "$EXIST" ]] || { ok "MLflow 인스턴스 이미 있음: $(echo $EXIST) — 변경하지 않습니다."; exit 0; }
DEF_SC=$(oc get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{end}')
[[ -n "$DEF_SC" ]] && ok "기본 StorageClass: $DEF_SC" || warn "기본 StorageClass 없음 — PVC가 Pending될 수 있습니다."

step "2. MLflow CR"
NSARG=()
if [[ "$(oc get crd mlflows.mlflow.opendatahub.io -o jsonpath='{.spec.scope}')" == Namespaced ]]; then NSARG=(-n "$AI_NS"); fi
f="$EVIDENCE_DIR/mlflow-cr.yaml"
cat >"$f" <<EOF
apiVersion: mlflow.opendatahub.io/v1
kind: MLflow
metadata:
  name: mlflow
$( ((${#NSARG[@]})) && printf '  namespace: %s' "$AI_NS")
spec:
  serveArtifacts: true
  artifactsDestination: "file:///mlflow/artifacts"
  backendStoreUri: "sqlite:////mlflow/mlflow.db"
  storage:
    size: ${MLFLOW_STORAGE_SIZE}
EOF
confirm "MLflow 인스턴스(SQLite, PVC ${MLFLOW_STORAGE_SIZE})를 만듭니까?"
k_apply "$f"
wait_for "MLflow 인스턴스 Available" 600 bash -c "oc get mlflows.mlflow.opendatahub.io mlflow ${NSARG[*]} -o jsonpath='{.status.conditions[?(@.type==\"Available\")].status}' | grep -qx True" \
  || warn "MLflow가 Available이 아닙니다: oc get mlflows.mlflow.opendatahub.io mlflow ${NSARG[*]} -o yaml"
log "운영 전환 시 SQLite 대신 PostgreSQL·S3를 쓴다(backendStoreUri·artifactsDestination 변경)."
