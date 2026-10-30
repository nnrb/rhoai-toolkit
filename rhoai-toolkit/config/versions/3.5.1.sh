# RHOAI 3.5.1 버전 정의 (3.5 = EUS 릴리스, 3.5.1 = 2026-09 보안 업데이트)
# 근거
#   - RHOAI 3.5 공식 문서: Release notes, Customizing the dashboard, MaaS, llm-d, Upgrading
#   - rhods-operator rhoai-3.5 브랜치 api/datasciencecluster/v2 (컴포넌트 17개: 3.4 14개 + ogx, aigateway, mcplifecycleoperator)
#   - odh-dashboard rhoai-3.5 브랜치 OdhDashboardConfig CRD
#   - RHOAI-Toolkit datasciencecluster-v3-35.yaml, 3.5-enable-dashboard-features.sh
# BC 클러스터 실측 전이다. 스크립트가 oc explain으로 필드 존재를 확인한 뒤 적용하므로 스키마에 없는 항목은 건너뛴다.
# 항목 형식: "<경로>=<값>"

VERSION_LABEL="RHOAI 3.5.1"
OCP_MIN_VERSION="4.19.9"
DSC_API="datasciencecluster.opendatahub.io/v2"

: "${CERT_MANAGER_CHANNEL:=stable-v1}"
: "${LWS_CHANNEL:=stable-v1.0}"
: "${RHCL_CHANNEL:=stable}"            # 3.5 문서 기준 RHCL 1.4.x. 1.4.0/1.4.1은 알려진 문제(인증 우회·rate limit) → 1.4.2 이상
: "${KUEUE_CHANNEL:=stable-v1.3}"       # 1.3 고정: Trainer가 RHBoK 1.4 이상과 비호환. 단 OCP 4.22에는 1.3이 없음
: "${JOBSET_CHANNEL:=stable-v1.0}"
: "${NFD_CHANNEL:=stable}"
: "${GPU_CHANNEL:=stable}"
: "${COO_CHANNEL:=stable}"
: "${OTEL_CHANNEL:=stable}"
: "${TEMPO_CHANNEL:=stable}"

# 3.5: MaaS가 kserve 하위에서 aigateway 컴포넌트로 이동(kserve.modelsAsService는 deprecated, Removed→Managed 전환을 CEL이 막음)
MAAS_DSC_ITEMS=(
  "aigateway.managementState=Managed"
  "aigateway.modelsAsAService.managementState=Managed"
)
if is_on "${FEATURE_BATCH_GATEWAY:-false}"; then MAAS_DSC_ITEMS+=("aigateway.batchGateway.managementState=Managed"); fi
# 3.4 condition(ModelsAsServiceReady)은 업그레이드 후에도 True로 남을 수 있어 제외한다.
MAAS_READY_REGEX="${MAAS_READY_REGEX:-^(AIGateway|ModelsAsAService).*Ready}"

# 3.5: Llama Stack → OGX (LlamaStackDistribution → OGXServer). OGX는 EUS 기간 지원 제외. 전환 안전장치는 version_dsc_guard.

DASHBOARD_FORBIDDEN=(
  "disableTrustyBiasMetrics"   # 3.4.2 MCP 메뉴 소실 이슈. 3.5.1 재현 여부 미확인 → 기본값 유지
  "mlflow"                     # 3.5: operator가 있으면 항상 켜짐(사용 안 함)
  "maasAuthPolicies"           # 3.5: 사용 안 함
  "disableFineTuning"
  "disableHardwareProfiles"    # Hardware profile GA
  "disableAcceleratorProfiles"
  "disableModelMesh"
)

# ---------------------------------------------------------------- DSC
version_dsc_items() {
  echo "dashboard.managementState=Managed"
  if is_on "$FEATURE_WORKBENCHES"; then echo "workbenches.managementState=Managed"; fi
  if is_on "$FEATURE_PIPELINES"; then echo "aipipelines.managementState=Managed"; fi
  if is_on "$FEATURE_KSERVE"; then
    echo "kserve.managementState=Managed"
    if is_on "$FEATURE_NIM"; then
      echo "kserve.nim.managementState=Managed"
      echo "kserve.nim.airGapped=true"          # 외부 NIM API 호출·모델 목록 조회 생략
    fi
    if is_on "$FEATURE_WVA"; then echo "kserve.wva.managementState=Managed"; fi
    if is_on "$FEATURE_MODEL_CACHE"; then
      echo "kserve.modelCache.managementState=Managed"
      echo "kserve.modelCache.cacheSize=${MODEL_CACHE_SIZE}"
      if [[ -n "${MODEL_CACHE_NODE_SELECTOR:-}" ]]; then
        [[ "$MODEL_CACHE_NODE_SELECTOR" == *=* ]] || die "MODEL_CACHE_NODE_SELECTOR는 key=value 형식이어야 합니다."
        echo "kserve.modelCache.nodeSelector=$(jq -cn --arg k "${MODEL_CACHE_NODE_SELECTOR%%=*}" --arg v "${MODEL_CACHE_NODE_SELECTOR#*=}" '{($k): $v}')"
      fi
    fi
  fi
  if is_on "$FEATURE_MODEL_REGISTRY"; then echo "modelregistry.managementState=Managed"; fi
  if is_on "$FEATURE_MLFLOW"; then echo "mlflowoperator.managementState=Managed"; fi
  if is_on "$FEATURE_FEAST"; then echo "feastoperator.managementState=Managed"; fi
  if is_on "$FEATURE_GENAI"; then
    echo "ogx.managementState=Managed"
    echo "llamastackoperator.managementState=Removed"
  fi
  if is_on "$FEATURE_MCP_LIFECYCLE"; then echo "mcplifecycleoperator.managementState=Managed"; fi
  if is_on "$FEATURE_RAY"; then echo "ray.managementState=Managed"; fi
  if is_on "$FEATURE_TRAINER"; then echo "trainer.managementState=Managed"; fi
  if is_on "$FEATURE_TRAINING_OPERATOR"; then echo "trainingoperator.managementState=Managed"; fi  # deprecated, 2027-03-27 EOL
  if is_on "$FEATURE_TRUSTYAI"; then
    echo "trustyai.managementState=Managed"
    echo "trustyai.eval.lmeval.permitCodeExecution=deny"
    echo "trustyai.eval.lmeval.permitOnline=deny"
  fi
  if is_on "$FEATURE_SPARK"; then echo "sparkoperator.managementState=Managed"; fi   # 3.5 GA
  if is_on "$FEATURE_KUEUE"; then
    echo "kueue.managementState=Unmanaged"
    # 3.5: autoCreateQueues=false(기본)이면 아래 이름은 참고값. 큐는 40-kueue.sh가 만든다.
    echo "kueue.defaultClusterQueueName=${KUEUE_QUEUE_NAME}"
    echo "kueue.defaultLocalQueueName=${KUEUE_QUEUE_NAME}"
  fi
  return 0
}

# Llama Stack → OGX 전환 안전장치 (20-dsc.sh가 ITEMS 계산 후 호출)
#   - 스키마에 ogx가 없으면 llamastackoperator를 Removed로 바꾸지 않는다.
#   - 기존 LlamaStackDistribution이 있으면 GENAI_OGX_MIGRATION_ACK=true 전까지 전환하지 않는다.
#     (3.5 업그레이드 문서: LSD를 삭제하고 업그레이드 후 OGXServer로 재생성)
version_dsc_guard() {
  is_on "$FEATURE_GENAI" || return 0
  if ! has_field datasciencecluster spec.components.ogx "$DSC_API"; then
    warn "DSC 스키마에 ogx가 없습니다. llamastackoperator를 Managed로 유지합니다."
    drop_items "ogx."
    drop_items "llamastackoperator."
    ITEMS+=("llamastackoperator.managementState=Managed")
    return 0
  fi
  local lsd
  lsd=$( (oc get llamastackdistributions -A --no-headers 2>/dev/null || true) | wc -l)
  if (( lsd > 0 )) && ! is_on "${GENAI_OGX_MIGRATION_ACK:-false}"; then
    warn "LlamaStackDistribution ${lsd}개가 있습니다. 설정을 백업하고 OGXServer 재생성 계획을 세운 뒤 GENAI_OGX_MIGRATION_ACK=true로 실행하세요."
    warn "이번 실행에서는 ogx/llamastackoperator 항목을 건너뜁니다."
    drop_items "ogx."
    drop_items "llamastackoperator."
  fi
  return 0
}

# ---------------------------------------------------------------- Dashboard
# 지원 단계는 3.5 "Customizing the dashboard" 표 기준. 3.5 기본값이 true인 항목
# (modelAsService, roleManagement, projectRBAC, trainingJobs, observabilityDashboard, gpuaas)도 명시해 의도를 남긴다.
version_dashboard_items() {
  # 공통·GA
  echo "disableTracking=true"
  echo "disableModelCatalog=false"
  echo "disableKServeMetrics=false"
  echo "disablePerformanceMetrics=false"
  echo "disableDistributedWorkloads=false"
  echo "roleManagement=true"
  if is_on "$FEATURE_MODEL_REGISTRY"; then
    echo "disableModelRegistry=false"
    echo "disableModelRegistrySecureDB=false"
  fi
  if is_on "$FEATURE_PIPELINES"; then echo "disablePipelines=false"; fi
  if is_on "$FEATURE_FEAST"; then echo "disableFeatureStore=false"; fi
  if is_on "$FEATURE_NIM"; then echo "disableNIMModelServing=false"; fi
  if is_on "$FEATURE_TRAINER"; then echo "trainingJobs=true"; fi
  if is_on "$FEATURE_OBSERVABILITY"; then echo "observabilityDashboard=true"; fi
  if is_on "$FEATURE_KUEUE"; then echo "gpuaas=true"; fi
  if is_on "$FEATURE_LLMD"; then echo "disableLLMd=false"; fi
  if is_on "$FEATURE_TRUSTYAI"; then echo "disableLMEval=false"; fi     # EvalHub(TP/GA 문서 상이) — 평가 이미지 반입 필요
  # Gen AI Studio (TP, 3.4와 같이 FEATURE_GENAI로 켠다). Playground는 OGX 필요
  if is_on "$FEATURE_GENAI"; then
    echo "genAiStudio=true"
    echo "aiAssetCustomEndpoints=true"
  fi
  # Technology Preview
  if is_on "$FEATURE_PREVIEW"; then
    echo "projectRBAC=true"
    echo "connectionTest=true"
    echo "deploymentWizardYAMLViewer=true"
    if is_on "$FEATURE_GENAI"; then
      echo "toolCalling=true"
      echo "guardrails=true"
      echo "externalModels=true"              # 폐쇄망: 내부 OpenAI 호환 endpoint만 등록
      echo "externalVectorStores=true"
      if is_on "$FEATURE_OBSERVABILITY"; then echo "genAiTracing=true"; fi
    fi
    if is_on "$FEATURE_MCP_LIFECYCLE"; then
      echo "mcpCatalog=true"
      echo "mcpRegistry=true"
    fi
    if is_on "$FEATURE_LLMD"; then
      echo "llmGatewayField=true"
      echo "llmdTemplates=true"
    fi
    if is_on "$FEATURE_FEAST"; then echo "featureStoreAdmin=true"; fi
    if is_on "$FEATURE_PIPELINES"; then
      echo "automl=true"
      echo "autorag=true"
    fi
    if is_on "$FEATURE_MLFLOW"; then
      echo "promptManagement=true"
      echo "globalProjectPrompts=true"
    fi
  fi
  # Developer Preview
  if is_on "$FEATURE_DEV_PREVIEW"; then
    if is_on "$FEATURE_KUEUE"; then echo "disableKueue=false"; fi      # 3.5 문서상 DP(Kueue hardware profile UI)
    if is_on "$FEATURE_GENAI"; then
      echo "agentsCatalog=true"               # 카탈로그 항목 이미지 반입 전에는 목록만 보임
      echo "agentOps=true"
      echo "agentConfigManagement=true"
    fi
  fi
  return 0
}

version_maas_dashboard_items() {
  echo "modelAsService=true"
  echo "vLLMDeploymentOnMaaS=true"            # TP
  return 0
}

version_prechecks() {
  local old
  old=$(oc get datasciencecluster "$DSC_NAME" -o jsonpath='{.spec.components.kserve.modelsAsService.managementState}' 2>/dev/null || true)
  if [[ "$old" == "Managed" ]]; then
    warn "kserve.modelsAsService=Managed(3.4 방식)가 남아 있습니다. aigateway를 먼저 켠 뒤 kserve 경로를 Removed로 바꿉니다(되돌릴 수 없음). docs/3.5.1/GUIDE.md 참고."
  fi
  if (( $( (oc get llamastackdistributions -A --no-headers 2>/dev/null || true) | wc -l) > 0 )); then
    warn "LlamaStackDistribution이 있습니다. 3.5에서는 OGXServer로 재생성해야 합니다."
  fi
  return 0
}
