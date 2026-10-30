#!/usr/bin/env bash
# OpenTelemetry 기반: Tempo(S3) + Console Traces 메뉴 + Tempo 접근 정책 + 운영 Collector(PROD_NS) + 쓰기 권한
#   사용: bash scripts/80-otel-base.sh apply   (기본 dry-run, 실제 적용은 DRY_RUN=false)
#         bash scripts/80-otel-base.sh test    (조회·합성 trace 전송: Collector 기동, 권한, 4318 수신 확인)
#   S3 자격증명은 Secret이 없을 때만 실행 중에 입력받는다(화면·파일에 남기지 않음).
#   선행: Tempo·OpenTelemetry·COO Operator(설치됨, 2026-10-28 점검)
source "$(dirname "$0")/lib/common.sh"
init
CMD=${1:-apply}
M="$WORK_ROOT/manifests/otel"; mkdir -p "$M"
COL=llm-otel          # OpenTelemetryCollector 이름 → Deployment·Service llm-otel-collector
GW_SVC="tempo-${TEMPO_STACK}-gateway"

case "$CMD" in
  apply)
    step "1. 선행 Operator·CRD"
    for crd in tempostacks.tempo.grafana.com opentelemetrycollectors.opentelemetry.io instrumentations.opentelemetry.io uiplugins.observability.openshift.io; do
      has_crd "$crd" && ok "CRD $crd" || die "CRD $crd 없음(Operator 설치 확인)"
    done
    oc get mutatingwebhookconfiguration -o name | grep -qi opentelemetry && ok "OpenTelemetry webhook" || warn "OpenTelemetry mutating webhook이 보이지 않습니다."

    step "2. Tempo namespace·S3 Secret"
    f="$EVIDENCE_DIR/otel-namespace.yaml"; printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: %s\n' "$TEMPO_NS" >"$f"
    oc get ns "$TEMPO_NS" >/dev/null 2>&1 && ok "namespace $TEMPO_NS 있음" || { confirm "namespace $TEMPO_NS 를 만듭니까?"; k_apply "$f"; }
    if oc get secret tempo-s3 -n "$TEMPO_NS" >/dev/null 2>&1; then
      ok "Secret $TEMPO_NS/tempo-s3 있음(변경하지 않음)"
    elif is_dry_run; then
      log "[dry-run] Secret $TEMPO_NS/tempo-s3 없음 → 실제 적용(DRY_RUN=false) 때 S3 값을 입력받습니다."
    else
      read -r -p "Tempo S3 endpoint(예: http://s3.example:9000): " S3_EP </dev/tty
      read -r -p "Tempo S3 bucket: " S3_BUCKET </dev/tty
      read -r -s -p "S3 access key: " S3_AK </dev/tty; echo
      read -r -s -p "S3 secret key: " S3_SK </dev/tty; echo
      [[ -n "$S3_EP" && -n "$S3_BUCKET" && -n "$S3_AK" && -n "$S3_SK" ]] || die "빈 값이 있습니다."
      put_secret tempo-s3 "$TEMPO_NS" "endpoint=$S3_EP" "bucket=$S3_BUCKET" "access_key_id=$S3_AK" "access_key_secret=$S3_SK"
      unset S3_AK S3_SK
    fi

    step "3. TempoStack $TEMPO_NS/$TEMPO_STACK (tenant $TEMPO_TENANT)"
    # S3가 사내 CA로 서명된 https이면 TEMPO_S3_CA_FILE을 지정한다(ConfigMap tempo-s3-ca의 service-ca.crt로 등록).
    TLS=""
    if [[ -n "${TEMPO_S3_CA_FILE:-}" ]]; then
      [[ -f "$TEMPO_S3_CA_FILE" ]] || die "TEMPO_S3_CA_FILE 파일이 없습니다: $TEMPO_S3_CA_FILE"
      oc create configmap tempo-s3-ca -n "$TEMPO_NS" --from-file=service-ca.crt="$TEMPO_S3_CA_FILE" --dry-run=client -o yaml >"$M/02a-tempo-s3-ca.yaml"
      k_apply "$M/02a-tempo-s3-ca.yaml"
      TLS=$'    tls:\n      enabled: true\n      caName: tempo-s3-ca'
    fi
    cat >"$M/02-tempostack.yaml" <<EOF
apiVersion: tempo.grafana.com/v1alpha1
kind: TempoStack
metadata:
  name: ${TEMPO_STACK}
  namespace: ${TEMPO_NS}
spec:
  storage:
    secret:
      name: tempo-s3
      type: s3
${TLS}
  storageSize: ${TEMPO_STORAGE_SIZE}
  tenants:
    mode: openshift
    authentication:
      - tenantName: ${TEMPO_TENANT}
        tenantId: "${TEMPO_TENANT_ID}"
  template:
    gateway:
      enabled: true
      rbac:
        enabled: false
    queryFrontend:
      jaegerQuery:
        enabled: true
EOF
    if oc get tempostack "$TEMPO_STACK" -n "$TEMPO_NS" >/dev/null 2>&1; then ok "TempoStack 있음(변경하지 않음)"; else confirm "TempoStack을 만듭니까?"; k_apply "$M/02-tempostack.yaml"; fi

    step "4. Console Traces 메뉴(UIPlugin distributed-tracing)"
    printf 'apiVersion: observability.openshift.io/v1alpha1\nkind: UIPlugin\nmetadata:\n  name: distributed-tracing\nspec:\n  type: DistributedTracing\n' >"$M/03-distributed-tracing-uiplugin.yaml"
    if oc get uiplugin distributed-tracing >/dev/null 2>&1; then ok "UIPlugin distributed-tracing 있음"; else confirm "UIPlugin distributed-tracing을 만듭니까?"; k_apply "$M/03-distributed-tracing-uiplugin.yaml"; fi

    step "5. Tempo Gateway 접근 정책(Console plugin, $PROD_NS Collector)"
    EXIST_NP=$(oc get networkpolicy -n "$TEMPO_NS" -o name 2>/dev/null | wc -l)
    if (( EXIST_NP == 0 )) && oc get tempostack "$TEMPO_STACK" -n "$TEMPO_NS" >/dev/null 2>&1; then
      warn "$TEMPO_NS에 NetworkPolicy가 없습니다. 첫 정책을 만들면 Tempo Gateway에 다른 namespace 접근이 막힙니다(기존 이용자 확인)."
    fi
    oc get networkpolicy -n "$TEMPO_NS" 2>/dev/null || true
    for pair in "allow-distributed-tracing-plugin-to-gateway:openshift-cluster-observability-operator" "allow-otel-collectors-to-gateway:${PROD_NS}"; do
      name=${pair%%:*}; src=${pair#*:}
      cat >"$M/04-$name.yaml" <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${name}
  namespace: ${TEMPO_NS}
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/component: gateway
      app.kubernetes.io/instance: ${TEMPO_STACK}
      app.kubernetes.io/name: tempo
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ${src}
      ports:
        - protocol: TCP
          port: 8080
        - protocol: TCP
          port: 8090
EOF
      confirm "NetworkPolicy $TEMPO_NS/$name 를 적용합니까?"
      k_apply "$M/04-$name.yaml"
    done

    step "6. 운영 Collector($PROD_NS/$COL)·Tempo 쓰기 권한"
    cat >"$M/05c-llm-otel-collector.yaml" <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${COL}-collector
  namespace: ${PROD_NS}
---
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: ${COL}
  namespace: ${PROD_NS}
spec:
  mode: deployment
  serviceAccount: ${COL}-collector
  resources:
    requests: {cpu: 200m, memory: 256Mi}
    limits: {cpu: "1", memory: 512Mi}
  config:
    extensions:
      bearertokenauth:
        filename: /var/run/secrets/kubernetes.io/serviceaccount/token
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318
    processors:
      memory_limiter:
        check_interval: 1s
        limit_mib: 400
        spike_limit_mib: 100
      batch: {}
    exporters:
      otlphttp/${TEMPO_TENANT}:
        endpoint: https://${GW_SVC}.${TEMPO_NS}.svc.cluster.local:8080/api/traces/v1/${TEMPO_TENANT}
        auth:
          authenticator: bearertokenauth
        headers:
          X-Scope-OrgID: ${TEMPO_TENANT}
        tls:
          ca_file: /var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt
          insecure: false
    service:
      extensions: [bearertokenauth]
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [otlphttp/${TEMPO_TENANT}]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: otel-tempostack-traces-write
rules:
  - apiGroups: [tempo.grafana.com]
    resources: [${TEMPO_TENANT}]
    resourceNames: [traces]
    verbs: [create]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: otel-tempostack-traces-write
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: otel-tempostack-traces-write
subjects:
  - kind: ServiceAccount
    name: ${COL}-collector
    namespace: ${PROD_NS}
EOF
    if oc get opentelemetrycollector "$COL" -n "$PROD_NS" >/dev/null 2>&1; then
      ok "OpenTelemetryCollector $PROD_NS/$COL 있음(변경하지 않음). 기존 otel Collector는 건드리지 않는다."
    else
      confirm "운영 Collector와 Tempo 쓰기 권한을 만듭니까?"
      k_apply "$M/05c-llm-otel-collector.yaml"
    fi
    wait_for "TempoStack Ready" 600 bash -c "oc get tempostack '$TEMPO_STACK' -n '$TEMPO_NS' -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -qx True" \
      || warn "TempoStack이 Ready가 아닙니다: oc get pod -n $TEMPO_NS"
    wait_for "Collector 기동" 300 oc rollout status "deploy/${COL}-collector" -n "$PROD_NS" --timeout=10s || warn "Collector 미기동"
    ;;

  test)
    step "1. Collector·권한"
    oc rollout status "deploy/${COL}-collector" -n "$PROD_NS" --timeout=180s
    PORTS=$(oc get svc "${COL}-collector" -n "$PROD_NS" -o jsonpath='{.spec.ports[*].port}')
    [[ " $PORTS " == *" 4318 "* ]] && ok "Service 포트: $PORTS" || warn "Service에 4318 포트 없음: $PORTS"
    [[ "$(oc auth can-i create "${TEMPO_TENANT}.tempo.grafana.com" --resource-name=traces --as="system:serviceaccount:${PROD_NS}:${COL}-collector" 2>/dev/null)" == yes ]] \
      && ok "Collector SA Tempo 쓰기 권한" || warn "Collector SA에 Tempo 쓰기 권한 없음"
    oc get pod -n "$TEMPO_NS" --no-headers | awk '{print "  " $1, $3}'

    step "2. 합성 trace 전송(port-forward 4318)"
    oc port-forward -n "$PROD_NS" "svc/${COL}-collector" 14318:4318 >/dev/null 2>&1 &
    PF=$!; trap 'kill $PF 2>/dev/null || true' EXIT; sleep 3
    NOW=$(date +%s%N); END=$((NOW + 1000000000))
    TRACE_ID=$(openssl rand -hex 16); SPAN_ID=$(openssl rand -hex 8)
    jq -n --arg t "$TRACE_ID" --arg s "$SPAN_ID" --arg st "$NOW" --arg en "$END" --arg v "$RHOAI_VERSION" \
      '{resourceSpans:[{resource:{attributes:[{key:"service.name",value:{stringValue:"rhoai-test"}},{key:"rhoai.version",value:{stringValue:$v}}]},
        scopeSpans:[{scope:{name:"manual-test"},spans:[{traceId:$t,spanId:$s,name:"manual-test-span",kind:2,startTimeUnixNano:$st,endTimeUnixNano:$en}]}]}]}' >"$EVIDENCE_DIR/otel-synthetic.json"
    CODE=$(curl -sS -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d @"$EVIDENCE_DIR/otel-synthetic.json" http://127.0.0.1:14318/v1/traces || true)
    [[ "$CODE" == 200 ]] && ok "OTLP 수신 200, TRACE_ID=$TRACE_ID" || warn "OTLP 응답 ${CODE:-연결 실패}"
    echo "rhoai-test TRACE_ID=$TRACE_ID" >>"$EVIDENCE_DIR/otel-trace-ids.txt"
    sleep 20
    ERR=$(collector_errors "${COL}-collector" "$PROD_NS" 3m)
    [[ "$ERR" == 0 ]] && ok "Collector 전송 오류 없음" || warn "Collector 로그 오류: ${ERR}(oc logs deploy/${COL}-collector -n $PROD_NS)"
    log "Console: Observe → Traces / ${TEMPO_NS}/${TEMPO_STACK} / tenant ${TEMPO_TENANT} / service rhoai-test / TRACE_ID=$TRACE_ID"
    ;;
  *) die "사용: $0 apply|test" ;;
esac
