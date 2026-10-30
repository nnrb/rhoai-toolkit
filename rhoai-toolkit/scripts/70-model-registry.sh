#!/usr/bin/env bash
# Model Registry 인스턴스(외부 PostgreSQL) 생성 + Model Catalog 폐쇄망 점검
#   - DB와 비밀번호 Secret(MR_DB_PASSWORD_SECRET, key: database-password)은 미리 준비한다.
#     (BC 환경 상세 절차: cluster-model-registry-postgresql16.ko.md)
#   - 인증 프록시 필드는 버전마다 다르므로 스키마에서 고른다(kubeRBACProxy → oauthProxy).
#   - Model Catalog는 메타데이터만 보여준다. 배포하려면 모델 아티팩트(oci modelcar 등)를 반입해야 한다.
source "$(dirname "$0")/lib/common.sh"
init

is_on "$FEATURE_MODEL_REGISTRY" || { log "FEATURE_MODEL_REGISTRY=false: 건너뜁니다."; exit 0; }

step "1. Model Registry 인스턴스"
MR_API=$(oc api-resources --api-group=modelregistry.opendatahub.io -o name 2>/dev/null | grep -m1 '^modelregistries' || true)
if [[ -z "$MR_API" ]]; then
  warn "ModelRegistry CRD가 없습니다. DSC modelregistry Managed 상태를 확인하세요."
elif [[ -z "$MR_DB_HOST" ]]; then
  log "MR_DB_HOST가 비어 있어 인스턴스 생성을 건너뜁니다(Dashboard > Settings > Model registry settings 에서 생성 가능)."
elif oc get modelregistries.modelregistry.opendatahub.io "$MR_NAME" -n "$MR_NS" >/dev/null 2>&1; then
  ok "ModelRegistry $MR_NS/$MR_NAME 이미 존재"
else
  oc get secret "$MR_DB_PASSWORD_SECRET" -n "$MR_NS" >/dev/null 2>&1 || is_dry_run \
    || die "DB 비밀번호 Secret $MR_NS/$MR_DB_PASSWORD_SECRET (key: database-password)이 없습니다."
  MR_VER=$(oc get crd modelregistries.modelregistry.opendatahub.io -o json \
    | jq -r '[.spec.versions[] | select(.storage) | .name][0]')
  AUTH='{}'
  for f in kubeRBACProxy oauthProxy; do
    if has_field modelregistry "spec.$f" "modelregistry.opendatahub.io/$MR_VER"; then AUTH=$(jq -cn --arg f "$f" '{($f): {}}'); break; fi
  done
  GRPC='{}'
  if has_field modelregistry spec.grpc "modelregistry.opendatahub.io/$MR_VER"; then GRPC='{"grpc":{}}'; fi
  [[ "$MR_DB_TYPE" == "postgres" || "$MR_DB_TYPE" == "mysql" ]] || die "MR_DB_TYPE은 postgres 또는 mysql"
  jq -n --arg v "modelregistry.opendatahub.io/$MR_VER" --arg n "$MR_NAME" --arg ns "$MR_NS" --arg t "$MR_DB_TYPE" \
        --arg h "$MR_DB_HOST" --argjson p "$MR_DB_PORT" --arg db "$MR_DB_NAME" --arg u "$MR_DB_USER" \
        --arg s "$MR_DB_PASSWORD_SECRET" --arg ssl "$MR_DB_SSLMODE" --argjson auth "$AUTH" --argjson grpc "$GRPC" '
    ({host: $h, port: $p, database: $db, username: $u, passwordSecret: {name: $s, key: "database-password"}}
      + (if $t == "postgres" then {sslMode: $ssl} else {} end)) as $dbspec
    | {apiVersion: $v, kind: "ModelRegistry",
       metadata: {name: $n, namespace: $ns},
       spec: ({rest: {}, ($t): $dbspec} + $auth + $grpc)}' \
    >"$EVIDENCE_DIR/model-registry.json"
  log "API $MR_VER, DB $MR_DB_TYPE, 인증 프록시: $(jq -c 'keys' <<<"$AUTH")"
  k_apply "$EVIDENCE_DIR/model-registry.json"
  wait_for "ModelRegistry Available" 600 \
    oc wait --for=condition=Available "modelregistries.modelregistry.opendatahub.io/$MR_NAME" -n "$MR_NS" --timeout=10s || true
fi

step "2. Model Catalog 소스 점검 (조회 전용)"
oc get configmap -n "$MR_NS" -o name 2>/dev/null | grep -i catalog || log "catalog ConfigMap 없음($MR_NS)"
OUT="$EVIDENCE_DIR/catalog-artifact-uris.txt"
oc get configmap -n "$MR_NS" -o json 2>/dev/null \
  | jq -r '.items[] | select(.metadata.name | test("catalog")) | .data // {} | .[]' \
  | grep -oE '(oci|hf|https?)://[^"[:space:]]+' | sort -u >"$OUT" || true
if [[ -s "$OUT" ]]; then
  log "catalog ConfigMap에 있는 아티팩트 URI $(wc -l <"$OUT")개 → $OUT"
  log "  oci://registry.redhat.io/... 는 내부 레지스트리로 미러(IDMS)하고, hf:// 는 폐쇄망에서 사용할 수 없습니다."
else
  log "ConfigMap에 아티팩트 URI가 없습니다. 기본 catalog는 이미지에 포함되어 있으며 Dashboard AI hub > Catalog에서 모델별 URI를 확인합니다."
fi
