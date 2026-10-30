#!/usr/bin/env bash
# 기능 선택(FEATURE_*)에 필요한 의존 오퍼레이터를 미러 카탈로그에서 설치한다.
#   이미 같은 패키지를 구독 중이면 건너뛴다. 채널은 config/versions/<버전>.sh 기본값을 쓴다.
#   Service Mesh 3는 OpenShift Gateway API가 관리하므로 여기서 설치하지 않는다(00-preflight에서 확인만).
source "$(dirname "$0")/lib/common.sh"
init envsubst

need() { local f; for f in "$@"; do is_on "${!f}" && return 0; done; return 1; }
# OPERATORS: 설치를 검토할 대상만 지정(공백 구분: cert-manager lws rhcl kueue jobset observability gpu). 비우면 전체.
#   04 작업계획서는 OPERATORS="lws rhcl"로 실행한다(BC는 FEATURE_RAY=true라 전체 실행 시 Kueue 구독이 만들어질 수 있음).
want() { [[ -z "${OPERATORS:-}" || " $OPERATORS " == *" $1 "* ]]; }

step "cert-manager (KServe·llm-d·MaaS·Kueue·분산 학습 공통)"
if want cert-manager && need FEATURE_KSERVE FEATURE_LLMD FEATURE_MAAS FEATURE_KUEUE FEATURE_GENAI FEATURE_RAY FEATURE_TRAINER; then
  ensure_operator openshift-cert-manager-operator cert-manager-operator "$CERT_MANAGER_CHANNEL" auto
fi

step "LeaderWorkerSet (llm-d)"
if want lws && need FEATURE_LLMD; then
  ensure_operator leader-worker-set openshift-lws-operator "$LWS_CHANNEL" auto
  if installplan_pending leader-worker-set; then
    warn "LWS InstallPlan 승인 대기 — 승인 후 이 단계를 다시 실행하면 LeaderWorkerSetOperator CR을 만듭니다."
  elif wait_for "LWS Operator CRD" 600 has_crd leaderworkersetoperators.operator.openshift.io; then
    apply_template "$TOOLKIT_ROOT/manifests/llmd/lws-operator.yaml"
  fi
fi

step "Red Hat Connectivity Link (MaaS 인증·토큰 제한)"
if want rhcl && need FEATURE_MAAS; then
  # 의존 Operator 구독이 다른 카탈로그를 보면 RHCL 의존성 해석이 실패한다 → 12-rhcl-deps.sh switch·승인을 먼저 한다.
  for p in $RHCL_DEPS; do
    S=$(find_subscription "$p")
    [[ -z "$S" || "$(oc get subscriptions.operators.coreos.com "${S#*/}" -n "${S%/*}" -o jsonpath='{.spec.source}')" == "$CATALOG_SOURCE" ]] \
      || die "$p 구독($S)이 $CATALOG_SOURCE를 보지 않습니다. 먼저 scripts/12-rhcl-deps.sh precheck·switch 후 11-installplan.sh $p 로 승인하세요."
    [[ -z "$S" || "$(oc get subscriptions.operators.coreos.com "${S#*/}" -n "${S%/*}" -o jsonpath='{.status.installedCSV}')" == "$(oc get subscriptions.operators.coreos.com "${S#*/}" -n "${S%/*}" -o jsonpath='{.status.currentCSV}')" ]] \
      || die "$p 업그레이드 승인·설치가 끝나지 않았습니다(installedCSV≠currentCSV). 11-installplan.sh $p 와 12-rhcl-deps.sh verify를 먼저 확인하세요."
  done
  # 승인 전 InstallPlan의 CSV 목록(rhcl·limitador·dns만 있는지)을 11-installplan.sh로 확인한다.
  STARTING_CSV=${RHCL_STARTING_CSV:-} ensure_operator rhcl-operator openshift-operators "$RHCL_CHANNEL" global
  # 1.4.0: Wasm shim 버그로 Gateway 인증 우회 가능. 1.4.0/1.4.1: rate limit 오동작(RHOAIENG-76586)
  RHCL_CSV=$(oc get csv -n openshift-operators -o name 2>/dev/null | sed -n 's#.*/\(rhcl-operator\.v[0-9.]*\)$#\1#p' | head -n1 || true)
  case "$RHCL_CSV" in
    rhcl-operator.v1.4.0) die "RHCL v1.4.0이 설치되어 있습니다. 1.4.2 이상으로 올린 뒤 MaaS를 구성하세요." ;;
    rhcl-operator.v1.4.1) warn "RHCL v1.4.1은 rate limit 알려진 문제가 있습니다. 1.4.2 이상 권장." ;;
    "") ;;
    *) ok "RHCL: $RHCL_CSV" ;;
  esac
fi

step "Red Hat build of Kueue"
if want kueue && need FEATURE_KUEUE; then
  ensure_operator kueue-operator openshift-kueue-operator "$KUEUE_CHANNEL" auto
fi

step "JobSet (Kubeflow Trainer v2)"
if want jobset && need FEATURE_TRAINER; then
  # RHOAI trainer 컴포넌트는 JobSetOperator CR 'cluster'와 jobset.x-k8s.io CRD를 확인한다.
  ensure_operator "$JOBSET_PACKAGE" "$JOBSET_NS" "$JOBSET_CHANNEL" auto
  if installplan_pending "$JOBSET_PACKAGE"; then
    warn "JobSet InstallPlan 승인 대기 — 승인 후 이 단계를 다시 실행하면 JobSetOperator CR을 만듭니다."
  elif wait_for "JobSet Operator CRD" 600 has_crd jobsetoperators.operator.openshift.io; then
    export JOBSET_NS
    apply_template "$TOOLKIT_ROOT/manifests/operators/jobset-operator.yaml"
  fi
fi

step "관측 스택 (COO·OpenTelemetry·Tempo)"
if want observability && need FEATURE_OBSERVABILITY; then
  ensure_operator cluster-observability-operator openshift-cluster-observability-operator "$COO_CHANNEL" auto
  ensure_operator opentelemetry-product openshift-opentelemetry-operator "$OTEL_CHANNEL" auto
  ensure_operator tempo-product openshift-tempo-operator "$TEMPO_CHANNEL" auto
fi

step "NFD·NVIDIA GPU Operator"
if want gpu && need FEATURE_GPU; then
  ensure_operator nfd openshift-nfd "$NFD_CHANNEL" auto
  ensure_operator gpu-operator-certified nvidia-gpu-operator "$GPU_CHANNEL" auto "$CERTIFIED_CATALOG_SOURCE"
  warn "NodeFeatureDiscovery·ClusterPolicy CR은 드라이버 이미지 미러 상태에 따라 현장 값으로 생성하세요(docs/01-airgap-mirroring.md)."
else
  log "FEATURE_GPU=false: GPU 스택 설치를 건너뜁니다(이미 설치된 환경)."
fi

step "결과"
oc get subscriptions.operators.coreos.com -A \
  -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,CHANNEL:.spec.channel,SOURCE:.spec.source,APPROVAL:.spec.installPlanApproval,CSV:.status.installedCSV
