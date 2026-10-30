#!/usr/bin/env bash
# 사전 백업(조회 전용). 작업계획서마다 첫 변경 전에 실행한다.
#   사용: bash scripts/01-backup.sh <rhoai342|maas|rhoai351>
#   경로: ${BACKUP_DIR}/<대상>/  (BACKUP_DIR은 config/env.sh 값. 바꾸려면 BACKUP_DIR=/경로 bash scripts/01-backup.sh <대상>)
#   이미 있는 파일은 덮어쓰지 않는다(적용 후 다시 실행해도 원복 기준 유지). 다시 받으려면 FORCE_BACKUP=true
#   Secret 데이터는 저장하지 않는다(이름 목록만). 파일 권한 600, 디렉터리 700
source "$(dirname "$0")/lib/common.sh"
init
TARGET=${1:-}
case "$TARGET" in rhoai342|maas|rhoai351) ;; *) die "사용: $0 <rhoai342|maas|rhoai351>" ;; esac
D=$(backup_dir "$TARGET")
step "사전 백업: $TARGET → $D"

# ---- 공통: 버전·Operator·RHOAI 설정·미러
save_once "$D/clusterversion.yaml"        oc get clusterversion version -o yaml
save_once "$D/csv.txt"                    oc get csv -A
save_once "$D/subscriptions.yaml"         oc get subscriptions.operators.coreos.com -A -o yaml
save_once "$D/installplans.txt"           oc get installplan -A
save_once "$D/dsc.yaml"                   oc get datasciencecluster "$DSC_NAME" -o yaml
save_once "$D/dsci.yaml"                  oc get dscinitialization "$DSCI_NAME" -o yaml
save_once "$D/dashboard.yaml"             oc get odhdashboardconfig "$DASH_NAME" -n "$AI_NS" -o yaml
save_once "$D/hardwareprofiles.yaml"      oc get hardwareprofiles.infrastructure.opendatahub.io -A -o yaml
save_once "$D/catalogsources.yaml"        oc get catalogsource -n openshift-marketplace -o yaml
save_once "$D/idms.yaml"                  oc get imagedigestmirrorset -o yaml
save_once "$D/itms.yaml"                  oc get imagetagmirrorset -o yaml
save_once "$D/pods-not-running.txt"       bash -c "oc get pods -A --no-headers | grep -vE 'Running|Completed' || true"

case "$TARGET" in
  rhoai342)
    save_once "$D/uiplugins.yaml"         oc get uiplugin -o yaml
    save_once "$D/prometheusrules-gpu.yaml" oc get prometheusrule -n nvidia-gpu-operator -o yaml
    save_once "$D/mlflows.yaml"           oc get mlflows.mlflow.opendatahub.io -A -o yaml
    save_once "$D/evalhubs.yaml"          oc get evalhubs.trustyai.opendatahub.io -A -o yaml
    save_once "$D/modelregistries.yaml"   oc get modelregistries.modelregistry.opendatahub.io -A -o yaml
    save_once "$D/genai-mcp-servers-cm.yaml" oc get configmap gen-ai-aa-mcp-servers -n "$AI_NS" -o yaml
    save_once "$D/llamastackdistributions.yaml" oc get llamastackdistributions -A -o yaml
    ;;
  maas)
    save_once "$D/kuadrant.yaml"          oc get kuadrant,limitador -n kuadrant-system -o yaml
    save_once "$D/authorinos.yaml"        oc get authorinos.operator.authorino.kuadrant.io -A -o yaml
    save_once "$D/authconfigs.txt"        oc get authconfig -A
    save_once "$D/gateways.yaml"          oc get gateway -A -o yaml
    save_once "$D/httproutes.yaml"        oc get httproute -A -o yaml
    save_once "$D/kuadrant-policies.yaml" oc get authpolicy,tokenratelimitpolicy -A -o yaml
    save_once "$D/maas-crs.yaml"          bash -c "oc get maasmodelrefs.maas.opendatahub.io,maassubscriptions.maas.opendatahub.io,maasauthpolicies.maas.opendatahub.io -A -o yaml 2>/dev/null; oc get tenants.maas.opendatahub.io -A -o yaml 2>/dev/null"
    save_once "$D/envoyfilters.yaml"      oc get envoyfilter -n openshift-ingress -o yaml
    save_once "$D/llmisvc.yaml"           oc get llminferenceservice -A -o yaml
    save_once "$D/isvc-$PROD_NS.yaml"     oc get inferenceservice -n "$PROD_NS" -o yaml
    save_once "$D/networkpolicies.yaml"   bash -c "for n in $PROD_NS $MODEL_NS $TEMPO_NS; do oc get networkpolicy -n \$n -o yaml 2>/dev/null; done"
    save_once "$D/otel.yaml"              bash -c "oc get instrumentation,opentelemetrycollector -A -o yaml 2>/dev/null; oc get tempostack -A -o yaml 2>/dev/null"
    save_once "$D/prod-pods.txt"          oc get pod -n "$PROD_NS" -o wide
    save_once "$D/secret-names.txt"       bash -c "for n in $AI_NS $MODEL_NS $TEMPO_NS kuadrant-system openshift-ingress; do oc get secret -n \$n --no-headers -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,TYPE:.type 2>/dev/null; done"
    ;;
  rhoai351)
    save_once "$D/rhods-subscription.yaml" bash -c "oc get subscriptions.operators.coreos.com -n redhat-ods-operator -o yaml"
    save_once "$D/llamastackdistributions.yaml" oc get llamastackdistributions -A -o yaml
    save_once "$D/llmisvc.yaml"           oc get llminferenceservice -A -o yaml
    save_once "$D/isvc.yaml"              oc get inferenceservice -A -o yaml
    save_once "$D/maas-crs.yaml"          bash -c "oc get maasmodelrefs.maas.opendatahub.io,maassubscriptions.maas.opendatahub.io,maasauthpolicies.maas.opendatahub.io -A -o yaml 2>/dev/null; oc get tenants.maas.opendatahub.io -A -o yaml 2>/dev/null"
    save_once "$D/gateways.yaml"          oc get gateway -A -o yaml
    save_once "$D/mlflows.yaml"           oc get mlflows.mlflow.opendatahub.io -A -o yaml
    save_once "$D/evalhubs.yaml"          oc get evalhubs.trustyai.opendatahub.io -A -o yaml
    # MaaS DB(API key 이력): 있으면 덤프한다. 파일 권한 600
    if oc get deploy maas-postgresql -n "$MAAS_DB_NS" >/dev/null 2>&1; then
      save_once "$D/maas-db.sql" oc exec -n "$MAAS_DB_NS" deploy/maas-postgresql -- pg_dump -d maas
      [[ -s "$D/maas-db.sql" ]] || warn "MaaS DB 덤프 실패(maas-postgresql은 있음) → 원인 확인 전 업그레이드하지 않는다."
    fi
    ;;
esac
log "백업 파일 $(find "$D" -type f | wc -l)개: $D"
ls -l "$D"
