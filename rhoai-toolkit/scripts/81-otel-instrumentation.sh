#!/usr/bin/env bash
# OpenTelemetry Python 자동 주입 설정(Instrumentation)과 Collector 접근 경로
#   1) PROD_NS에 Ingress를 제한하는 NetworkPolicy가 있으면 같은 namespace + MODEL_NS → Collector 4318 허용 정책 추가
#   2) PROD_NS에 Instrumentation(INSTRUMENTATION_NAME) 생성. 검증 모델(MODEL_NS)도 이 Instrumentation을 참조한다.
#   모델 Pod는 바뀌지 않는다(주입은 82-otel-models.sh가 모델별 annotation으로 켠다).
#   사용: bash scripts/81-otel-instrumentation.sh   (기본 dry-run, 실제 적용은 DRY_RUN=false)
source "$(dirname "$0")/lib/common.sh"
init
M="$WORK_ROOT/manifests/otel"; mkdir -p "$M"
[[ -n "$OTEL_PYTHON_IMAGE" && "${OTEL_PYTHON_IMAGE:0:1}" != "<" ]] || die "config/env.sh의 OTEL_PYTHON_IMAGE를 지정하세요."
[[ "$PROD_OTLP_BASE" == http://*:4318 ]] || die "PROD_OTLP_BASE는 http://...:4318 형식이어야 합니다(/v1/traces 제외)."

step "1. Collector 접근 경로"
# Collector Pod를 선택하는 Ingress 정책이 있을 때만 허용 정책을 더한다(없으면 새 정책이 Collector를 처음으로 격리하게 됨).
CL=$( (oc get pod -n "$PROD_NS" -l app.kubernetes.io/name=llm-otel-collector -o json 2>/dev/null || echo '{"items":[]}') \
  | jq -c '.items[0].metadata.labels // {"app.kubernetes.io/name":"llm-otel-collector"}')
NP_IN=$(oc get networkpolicy -n "$PROD_NS" -o json | jq --argjson l "$CL" '[.items[]
  | select((.spec.policyTypes // ["Ingress"]) | index("Ingress"))
  | select((.spec.podSelector.matchExpressions != null) or ((.spec.podSelector.matchLabels // {}) | to_entries | all(. as $e | $l[$e.key] == $e.value)))] | length')
oc get networkpolicy -n "$MODEL_NS" --no-headers 2>/dev/null | sed 's/^/  '"$MODEL_NS"' /' || true
if (( NP_IN == 0 )); then
  ok "$PROD_NS에 Collector를 선택하는 Ingress 정책 없음(Collector 접근 허용 상태) — 추가하지 않음"
else
  cat >"$M/04c-allow-otlp-to-otel-collector.yaml" <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-otlp-to-otel-collector
  namespace: ${PROD_NS}
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: llm-otel-collector
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector: {}
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ${MODEL_NS}
      ports:
        - protocol: TCP
          port: 4318
        - protocol: TCP
          port: 4317
EOF
  confirm "$PROD_NS에 Collector 4318 허용 정책(같은 namespace + $MODEL_NS)을 적용합니까?"
  k_apply "$M/04c-allow-otlp-to-otel-collector.yaml"
fi
log "MODEL_NS에 Egress 제한 정책이 있으면 $PROD_NS 4318 허용을 담당자와 협의한다."

step "2. Instrumentation $PROD_NS/$INSTRUMENTATION_NAME"
cat >"$M/instrumentation-${PROD_NS}.yaml" <<EOF
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: ${INSTRUMENTATION_NAME}
  namespace: ${PROD_NS}
spec:
  exporter:
    endpoint: ${PROD_OTLP_BASE}
  propagators: [tracecontext, baggage]
  sampler:
    type: parentbased_traceidratio
    argument: "${OTEL_SAMPLE_RATIO}"
  python:
    image: ${OTEL_PYTHON_IMAGE}
    env:
      - {name: OTEL_EXPORTER_OTLP_PROTOCOL, value: http/protobuf}
      - {name: OTEL_EXPORTER_OTLP_TRACES_PROTOCOL, value: http/protobuf}
      - {name: OTEL_TRACES_EXPORTER, value: otlp}
      - {name: OTEL_METRICS_EXPORTER, value: none}
      - {name: OTEL_LOGS_EXPORTER, value: none}
    resourceRequirements:
      requests: {cpu: 50m, memory: 64Mi}
      limits: {cpu: 500m, memory: 256Mi}
EOF
if oc get instrumentation "$INSTRUMENTATION_NAME" -n "$PROD_NS" >/dev/null 2>&1; then
  backup instrumentation "$INSTRUMENTATION_NAME" "$PROD_NS"
  warn "Instrumentation이 이미 있습니다. 내용이 다르면 apply로 갱신됩니다(diff 확인)."
  oc diff -f "$M/instrumentation-${PROD_NS}.yaml" || true
fi
confirm "Instrumentation $PROD_NS/$INSTRUMENTATION_NAME 을 적용합니까?"
k_apply "$M/instrumentation-${PROD_NS}.yaml"
oc get instrumentation -n "$PROD_NS" 2>/dev/null || true
