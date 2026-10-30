# RHOAI 3.4.2 버전 정의
# 근거
#   - 3.4.2 클러스터 실측: oc explain datasciencecluster.spec.components / odhdashboardconfig.spec (2026-09-15~29)
#   - RHOAI 3.4 공식 문서(Customizing the dashboard, MaaS, llm-d, Kueue)
#   - RHOAI-Toolkit install-rhoai-34.sh, enable-dashboard-features.sh
# 항목 형식: "<경로>=<값>". 경로가 설치된 스키마에 없으면 스크립트가 건너뛴다.

VERSION_LABEL="RHOAI 3.4.2"
OCP_MIN_VERSION="4.19.9"
DSC_API="datasciencecluster.opendatahub.io/v2"

# 의존 오퍼레이터 채널(미러 카탈로그와 대조. 다르면 config/env.sh에서 덮어쓴다)
: "${CERT_MANAGER_CHANNEL:=stable-v1}"
: "${LWS_CHANNEL:=stable-v1.0}"
: "${RHCL_CHANNEL:=stable}"            # RHCL 1.3 이상. 1.4.0은 Wasm 인증 우회 버그로 사용 금지(1.4.1+)
: "${KUEUE_CHANNEL:=stable-v1.3}"       # 1.3 고정: Kubeflow Trainer는 RHBoK 1.4 이상과 비호환(RHOAIENG-87965)
: "${JOBSET_CHANNEL:=stable-v1.0}"
: "${NFD_CHANNEL:=stable}"
: "${GPU_CHANNEL:=stable}"
: "${COO_CHANNEL:=stable}"
: "${OTEL_CHANNEL:=stable}"
: "${TEMPO_CHANNEL:=stable}"

# MaaS를 켜는 DSC 경로 (3.4.x: kserve 하위)
MAAS_DSC_ITEMS=(
  "kserve.modelsAsService.managementState=Managed"
)
# MaaS가 준비되었는지 보는 DSC condition 이름(정규식)
MAAS_READY_REGEX="${MAAS_READY_REGEX:-^ModelsAsServiceReady$}"

# 명시하면 안 되는 Dashboard 필드(사유)
DASHBOARD_FORBIDDEN=(
  "disableTrustyBiasMetrics"   # 3.4.2에서 false를 명시하면 MCP 메뉴가 사라짐(재현 확인). 기본값 false 유지
  "mlflow"                     # 3.4에서 deprecated. mlflowoperator + 인스턴스로 사용
  "disableFineTuning"          # deprecated, 효과 없음
  "disableHardwareProfiles"    # 3.x에서 사용하지 않음
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
      echo "kserve.nim.airGapped=true"
    fi
    if is_on "$FEATURE_WVA"; then echo "kserve.wva.managementState=Managed"; fi
  fi
  if is_on "$FEATURE_MODEL_REGISTRY"; then echo "modelregistry.managementState=Managed"; fi
  if is_on "$FEATURE_MLFLOW"; then echo "mlflowoperator.managementState=Managed"; fi
  if is_on "$FEATURE_FEAST"; then echo "feastoperator.managementState=Managed"; fi
  if is_on "$FEATURE_GENAI"; then echo "llamastackoperator.managementState=Managed"; fi
  if is_on "$FEATURE_RAY"; then echo "ray.managementState=Managed"; fi
  if is_on "$FEATURE_TRAINER"; then echo "trainer.managementState=Managed"; fi
  if is_on "$FEATURE_TRAINING_OPERATOR"; then echo "trainingoperator.managementState=Managed"; fi
  if is_on "$FEATURE_TRUSTYAI"; then
    echo "trustyai.managementState=Managed"
    # 폐쇄망: 평가 작업의 원격 코드 실행·온라인 다운로드 금지(두 필드 모두 필수)
    echo "trustyai.eval.lmeval.permitCodeExecution=deny"
    echo "trustyai.eval.lmeval.permitOnline=deny"
  fi
  if is_on "$FEATURE_SPARK"; then echo "sparkoperator.managementState=Managed"; fi
  if is_on "$FEATURE_KUEUE"; then
    echo "kueue.managementState=Unmanaged"
    echo "kueue.defaultClusterQueueName=${KUEUE_QUEUE_NAME}"
    echo "kueue.defaultLocalQueueName=${KUEUE_QUEUE_NAME}"
  fi
  return 0
}

# 20-dsc.sh가 ITEMS 배열을 계산한 뒤 호출한다. 3.4.2는 추가 조정 없음.
version_dsc_guard() {
  return 0
}

# ---------------------------------------------------------------- Dashboard
# MaaS 관련 플래그는 scripts/62-maas.sh가 백엔드 구성 후에 켠다.
version_dashboard_items() {
  # 공통
  echo "disableTracking=true"                 # 폐쇄망: 사용 데이터 외부 전송 중지
  echo "disableModelCatalog=false"
  echo "disableKServeMetrics=false"
  echo "disablePerformanceMetrics=false"
  echo "disableDistributedWorkloads=false"
  if is_on "$FEATURE_MODEL_REGISTRY"; then
    echo "disableModelRegistry=false"
    echo "disableModelRegistrySecureDB=false"
  fi
  if is_on "$FEATURE_PIPELINES"; then echo "disablePipelines=false"; fi
  if is_on "$FEATURE_FEAST"; then echo "disableFeatureStore=false"; fi
  if is_on "$FEATURE_NIM"; then echo "disableNIMModelServing=false"; fi
  # Gen AI Studio (TP)
  if is_on "$FEATURE_GENAI"; then
    echo "genAiStudio=true"
    echo "aiAssetCustomEndpoints=true"
  fi
  # Kueue / 학습
  if is_on "$FEATURE_KUEUE"; then echo "disableKueue=false"; fi
  if is_on "$FEATURE_TRAINER"; then echo "trainingJobs=true"; fi
  # llm-d
  if is_on "$FEATURE_LLMD"; then
    echo "disableLLMd=false"
    echo "llmGatewayField=true"
    echo "deploymentWizardYAMLViewer=true"
  fi
  # 평가(Eval Hub, TP) — 메뉴만 켜진다. EvalHub와 평가 이미지 반입 필요
  if is_on "$FEATURE_TRUSTYAI"; then echo "disableLMEval=false"; fi
  # 통합 관측 (TP) — DSCI monitoring 구성 후
  if is_on "$FEATURE_OBSERVABILITY"; then echo "observabilityDashboard=true"; fi
  # Technology Preview (3.4 문서 표 기준)
  if is_on "$FEATURE_PREVIEW"; then
    echo "projectRBAC=true"
    if is_on "$FEATURE_MLFLOW"; then echo "promptManagement=true"; fi
    if is_on "$FEATURE_PIPELINES"; then
      echo "automl=true"                      # AutoML/AutoRAG 파이프라인 이미지·pipelines-components 저장소 반입 필요
      echo "autorag=true"
    fi
  fi
  # Developer Preview
  if is_on "$FEATURE_DEV_PREVIEW"; then
    echo "mcpCatalog=true"                    # MCP 서버 이미지 반입 전에는 메뉴만 보임
    echo "externalVectorStores=true"          # 기존 vector store 연결 정보 필요
  fi
  return 0
}

# MaaS 메뉴 (scripts/62-maas.sh)
version_maas_dashboard_items() {
  echo "modelAsService=true"
  echo "maasAuthPolicies=true"
  echo "vLLMDeploymentOnMaaS=true"            # TP. 문서에 vLLMDeploymentOnMaas 표기도 있으나 3.4.2 클러스터 적용 확인된 표기 사용
  return 0
}

# 버전 고유 사전 점검
version_prechecks() {
  return 0
}
