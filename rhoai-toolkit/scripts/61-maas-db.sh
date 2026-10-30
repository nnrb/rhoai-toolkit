#!/usr/bin/env bash
# MaaS DB: PostgreSQL(내부 생성 또는 외부) + maas-api 접속 Secret(maas-db-config / DB_CONNECTION_URL)
#   반영한 현장 이슈
#     TS-01: 클러스터 내 PostgreSQL은 TLS를 쓰지 않으므로 sslmode=disable
#     TS-17: 기존 계정 Secret이 있으면 비밀번호를 재생성하지 않는다(재생성 시 DB 인증 실패)
#   비밀번호는 화면·EVIDENCE_DIR에 남기지 않는다.
source "$(dirname "$0")/lib/common.sh"
init envsubst openssl

is_on "$FEATURE_MAAS" || { log "FEATURE_MAAS=false: 건너뜁니다."; exit 0; }
# put_secret은 lib/common.sh (임시 파일 자동 삭제, dry-run 실패는 경고)

if [[ "$MAAS_DB_MODE" == "external" ]]; then
  step "외부 PostgreSQL 사용"
  [[ -n "$MAAS_DB_EXTERNAL_URL" ]] || die "MAAS_DB_EXTERNAL_URL이 필요합니다(postgresql://user:pass@host:5432/db?sslmode=...)."
  [[ "$MAAS_DB_EXTERNAL_URL" == postgresql://* ]] || die "MAAS_DB_EXTERNAL_URL 형식 오류"
  DB_URL=$MAAS_DB_EXTERNAL_URL
else
  step "1. 내부 PostgreSQL 계정 Secret"
  if oc get secret maas-postgresql -n "$MAAS_DB_NS" >/dev/null 2>&1; then
    ok "기존 maas-postgresql Secret 사용(비밀번호 유지)"
    DB_PASS=$(oc get secret maas-postgresql -n "$MAAS_DB_NS" -o jsonpath='{.data.database-password}' | base64 -d)
  else
    DB_PASS=${MAAS_DB_PASSWORD:-$(openssl rand -hex 24)}
    put_secret maas-postgresql "$MAAS_DB_NS" database-user=maas "database-password=$DB_PASS" database-name=maas
  fi

  step "2. PostgreSQL 배포"
  if [[ -z "$STORAGE_CLASS" ]]; then
    STORAGE_CLASS=$(oc get sc -o json | jq -r '[.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true") | .metadata.name][0] // empty')
    [[ -n "$STORAGE_CLASS" ]] || die "STORAGE_CLASS를 지정하세요(기본 StorageClass 없음)."
    log "기본 StorageClass 사용: $STORAGE_CLASS"
  fi
  export MAAS_DB_NS MAAS_DB_IMAGE MAAS_DB_SIZE STORAGE_CLASS
  apply_template "$TOOLKIT_ROOT/manifests/maas/postgresql.yaml"
  wait_for "PostgreSQL Ready" 600 oc rollout status deployment/maas-postgresql -n "$MAAS_DB_NS" --timeout=10s \
    || die "PostgreSQL이 기동하지 않습니다: oc describe pod -l app=maas-postgresql -n $MAAS_DB_NS"

  # 바인딩된 PV를 Retain으로: PVC 삭제 시 데이터 보존
  if ! is_dry_run; then
    PV=$(oc get pvc maas-postgresql-data -n "$MAAS_DB_NS" -o jsonpath='{.spec.volumeName}')
    if [[ -n "$PV" ]]; then oc patch pv "$PV" --type=merge -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}' >/dev/null && ok "PV $PV Retain"; fi
    # 데이터 디렉터리가 PVC에 있는지 확인(TS-17)
    oc exec -n "$MAAS_DB_NS" deployment/maas-postgresql -- df -h /var/lib/pgsql/data | tail -n1
  fi
  # 비밀번호에 @ : / ? # % 가 있어도 URL이 깨지지 않도록 인코딩한다.
  DB_PASS_ENC=$(DB_PASS="$DB_PASS" jq -rn 'env.DB_PASS | @uri')   # 인자 대신 환경변수로 전달(ps 노출 방지)
  DB_URL="postgresql://maas:${DB_PASS_ENC}@maas-postgresql.${MAAS_DB_NS}.svc.cluster.local:5432/maas?sslmode=disable"
  unset DB_PASS_ENC
fi

step "3. maas-db-config Secret ($MAAS_DB_NS)"
put_secret maas-db-config "$MAAS_DB_NS" "DB_CONNECTION_URL=$DB_URL"
unset DB_URL DB_PASS
log "maas-api가 다른 namespace에서 실행되면 62-maas.sh가 그 namespace로 복사합니다."
