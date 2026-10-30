# 현장 설정 파일 예시.
#   cp config/env.example.sh config/env.sh  후 값을 채운다. config/env.sh는 .gitignore 대상이다.
#   모든 값은 "환경변수 > 이 파일 > 기본값" 순으로 적용된다.  예) DRY_RUN=false ./scripts/rhoai-enable.sh dashboard

# ------------------------------------------------------------------ 기본
: "${RHOAI_VERSION:=3.4.2}"            # 3.4.2 | 3.5.1  (config/versions/<버전>.sh 를 읽는다)
: "${DRY_RUN:=true}"                   # true: --dry-run=server 검증만 / false: 실제 적용
: "${ASSUME_YES:=false}"               # true: 확인 질문 생략(자동화용)

# ------------------------------------------------------------------ 폐쇄망 카탈로그
# oc-mirror v2가 만든 CatalogSource 이름 (oc get catalogsource -n openshift-marketplace)
#   RHOAI 폐쇄망 설치 문서 기본값은 cs-redhat-operator-index. 현장 이름이 다르면 바꾼다.
: "${CATALOG_SOURCE:=cs-redhat-operator-index}"
# NVIDIA GPU Operator는 certified 카탈로그에 있다. 미러하지 않았으면 FEATURE_GPU=false
: "${CERTIFIED_CATALOG_SOURCE:=cs-certified-operator-index}"
: "${INSTALL_PLAN_APPROVAL:=Manual}"   # 폐쇄망 운영 권장: Manual
: "${APPROVE_INSTALLPLAN:=false}"      # true: 이 툴킷이 만든 구독의 첫 InstallPlan을 승인
: "${INTERNAL_REGISTRY:=registry.example.internal:8443}"   # 스크립트는 쓰지 않음. 샘플 YAML의 이미지 경로 치환 참고값

# ------------------------------------------------------------------ 클러스터 값
: "${APPS_DOMAIN:=}"                   # 비우면 ingresses.config/cluster 의 spec.domain 사용
: "${STORAGE_CLASS:=}"                 # DB PVC용. 비우면 기본 StorageClass (DB는 block 계열 권장. 예: ontap-iscsi)
: "${INTERNAL_CA_FILE:=}"              # 사내 CA PEM(내부 S3·레지스트리·DB). 22-trusted-ca.sh가 DSCI customCABundle에 넣는다
: "${MODEL_NAMESPACES:=}"              # 모델을 배포할 namespace 목록(쉼표). Gateway 접근 label 대상

# ------------------------------------------------------------------ 기능 선택 (true/false)
: "${FEATURE_WORKBENCHES:=true}"
: "${FEATURE_PIPELINES:=true}"
: "${FEATURE_KSERVE:=true}"
: "${FEATURE_MODEL_REGISTRY:=true}"
: "${FEATURE_MLFLOW:=true}"
: "${FEATURE_FEAST:=true}"
: "${FEATURE_GENAI:=true}"             # 3.4.2: llamastackoperator / 3.5.1: ogx (전환 주의: docs/3.5.1/GUIDE.md)
: "${FEATURE_RAY:=true}"
: "${FEATURE_TRAINER:=true}"           # Kubeflow Trainer v2. JobSet Operator 필요
: "${FEATURE_TRAINING_OPERATOR:=false}" # Training Operator v1 (deprecated). 기존 PyTorchJob을 쓰는 경우만 true
: "${FEATURE_TRUSTYAI:=true}"          # 평가(LMEval)·bias·guardrails
: "${FEATURE_SPARK:=true}"
: "${FEATURE_KUEUE:=true}"             # Red Hat build of Kueue + DSC kueue: Unmanaged
: "${FEATURE_MAAS:=true}"              # RHCL + Gateway + PostgreSQL 필요
: "${FEATURE_LLMD:=true}"              # LeaderWorkerSet + Gateway 필요
: "${FEATURE_NIM:=false}"              # NGC 이미지 반입 필요. airGapped 모드로 설정
: "${FEATURE_WVA:=false}"              # llm-d Workload Variant Autoscaler (TP)
: "${FEATURE_MCP_LIFECYCLE:=true}"     # 3.5.1 이상: MCP 서버 수명주기 Operator
: "${FEATURE_OBSERVABILITY:=true}"     # DSCI monitoring + COO/OTel/Tempo
: "${FEATURE_GPU:=false}"              # NFD/NVIDIA GPU Operator 신규 설치(이미 설치되어 있으면 false)
: "${FEATURE_MODEL_CACHE:=false}"      # 3.5.1: KServe 노드 로컬 모델 캐시. MODEL_CACHE_SIZE·노드 지정 필요
: "${FEATURE_BATCH_GATEWAY:=false}"    # 3.5.1: aigateway Batch API
: "${FEATURE_PREVIEW:=true}"           # Dashboard의 Technology Preview(TP) 메뉴
: "${FEATURE_DEV_PREVIEW:=true}"       # Dashboard의 Developer Preview(DP) 메뉴 (지원 대상 아님)

# ------------------------------------------------------------------ 오퍼레이터 이름(카탈로그와 다르면 변경)
: "${JOBSET_PACKAGE:=job-set}"         # 미러 카탈로그의 JobSet 패키지 이름(oc get packagemanifests | grep -i jobset)
: "${JOBSET_NS:=openshift-jobset-operator}"

# ------------------------------------------------------------------ KServe 모델 캐시 (3.5.1, FEATURE_MODEL_CACHE=true)
: "${MODEL_CACHE_SIZE:=500Gi}"
: "${MODEL_CACHE_NODE_SELECTOR:=}"     # 예) node-role.kubernetes.io/gpu=  (key=value 한 쌍)

# ------------------------------------------------------------------ Kueue
: "${KUEUE_QUEUE_NAME:=default}"       # DSC kueue.defaultClusterQueueName/defaultLocalQueueName과 같아야 함
: "${KUEUE_NAMESPACES:=}"              # LocalQueue를 만들고 kueue.openshift.io/managed=true 를 붙일 프로젝트(쉼표)
: "${KUEUE_FRAMEWORKS:=BatchJob,Pod,Deployment,StatefulSet,RayJob,RayCluster,PyTorchJob,JobSet}"  # 신규 Kueue 인스턴스에만 적용
: "${KUEUE_CPU_QUOTA:=64}"
: "${KUEUE_MEMORY_QUOTA:=256Gi}"
: "${KUEUE_GPU_QUOTA:=4}"
: "${GPU_RESOURCE_NAME:=nvidia.com/gpu}" # MIG 사용 시 nvidia.com/mig-<profile> 등 노드 allocatable 이름

# ------------------------------------------------------------------ MaaS
: "${MAAS_DB_MODE:=internal}"          # internal: 클러스터 내 PostgreSQL 생성 / external: 기존 DB 사용
: "${MAAS_DB_NS:=redhat-ods-applications}"  # PostgreSQL과 maas-db-config를 먼저 만드는 곳.
                                       # 3.5.1은 maas-api가 infra namespace(기본 redhat-ai-gateway-infra)에서 돌므로 62-maas.sh가 그곳으로 Secret을 복사한다
: "${MAAS_DB_IMAGE:=registry.redhat.io/rhel9/postgresql-16@sha256:cb16884277c60ba0e2adfd7d0342eb87e651c0ecdbe8c8471615059b5c722846}"
: "${MAAS_DB_SIZE:=20Gi}"
: "${MAAS_DB_PASSWORD:=}"              # 비우면 생성하여 Secret에만 저장(화면 출력 안 함)
: "${MAAS_DB_EXTERNAL_URL:=}"          # external일 때 postgresql://user:pass@host:5432/db?sslmode=require
: "${MAAS_HOSTNAME:=}"                 # 비우면 maas.<APPS_DOMAIN>
: "${MAAS_TLS_SECRET:=maas-gateway-tls}"
: "${MAAS_TLS_CERT_FILE:=}"            # 서버 인증서+중간 CA PEM. 비우면 Secret이 이미 있어야 함
: "${MAAS_TLS_KEY_FILE:=}"
: "${GATEWAY_CLASS:=}"                 # 비우면 data-science-gateway-class → openshift-default 순으로 자동 선택
# Gateway에 Route를 붙일 수 있는 namespace label 키. Gateway가 이미 있으면 그 selector에서 자동으로 읽는다.
#   BC 3.4.2 클러스터 값: platform.bcnuri.com/maas-gateway-access / Red Hat 문서 예: maas-gateway-access
#   from: All 은 쓰지 않는다(RHOAIENG-80360).
: "${GATEWAY_ACCESS_LABEL:=platform.bcnuri.com/maas-gateway-access}"
: "${RHCL_AUTH_TIMEOUT:=2s}"           # Authorino 인증 timeout (기본 200ms는 부하 시 실패)

# ------------------------------------------------------------------ llm-d
: "${LLMD_STANDALONE_GATEWAY:=true}"   # false: openshift-ai-inference Gateway를 만들지 않음(MaaS Gateway만 사용)
: "${LLMD_GATEWAY_NAME:=openshift-ai-inference}"
: "${LLMD_HOSTNAME:=}"                 # 비우면 inference-gateway.<APPS_DOMAIN>
: "${LLMD_TLS_SECRET:=llmd-gateway-tls}"
: "${LLMD_TLS_CERT_FILE:=}"            # 서버 인증서+중간 CA PEM (SAN=LLMD_HOSTNAME). 비우면 Secret이 이미 있어야 함
: "${LLMD_TLS_KEY_FILE:=}"

# ------------------------------------------------------------------ Model Registry
: "${MR_NAME:=model-registry}"
: "${MR_NS:=rhoai-model-registries}"
: "${MR_DB_TYPE:=postgres}"           # postgres | mysql (Red Hat 지원 구성표는 MySQL 8 권장, BC는 PostgreSQL 16 검증)
: "${MR_DB_HOST:=}"                    # 비우면 Model Registry 인스턴스 생성 단계를 건너뜀
: "${MR_DB_PORT:=5432}"                # mysql이면 3306
: "${MR_DB_NAME:=modelregistry}"
: "${MR_DB_USER:=modelregistry}"
: "${MR_DB_PASSWORD_SECRET:=model-registry-db}"   # 미리 만든 Secret (key: database-password)
: "${MR_DB_SSLMODE:=disable}"         # postgres 전용

# ------------------------------------------------------------------ Gen AI 폐쇄망
: "${GENAI_CLUSTER_DOMAINS:=}"         # Gen AI Studio에서 허용할 내부 endpoint 도메인(쉼표). 예) svc.cluster.local,apps.ocp.example.com
: "${GENAI_EXTERNAL_PROVIDERS:=false}"

# ------------------------------------------------------------------ 관측
: "${MONITORING_NS:=redhat-ods-monitoring}"
: "${METRICS_STORAGE_SIZE:=5Gi}"
: "${METRICS_RETENTION:=90d}"
: "${TRACES_BACKEND:=pv}"              # pv | s3 (s3는 TRACES_S3_SECRET 필요)
: "${TRACES_RETENTION:=2160h}"
: "${TRACES_SAMPLE_RATIO:=0.1}"
: "${TRACES_S3_SECRET:=}"              # TRACES_BACKEND=s3 일 때 버킷 접속 Secret 이름

# ------------------------------------------------------------------ RHOAI-Toolkit(hyogrin) 데모 구성에서 가져온 항목
#   스크립트가 직접 띄우는 Pod 이미지는 mirror/runtime-images.txt에 있다(./bc-toolkit.sh images로 반입 확인).
: "${FEATURE_OBS_UI:=true}"            # 23-observability-ui: COO UIPlugin(dashboards·monitoring+Perses), GPU accelerator_* recording rule
: "${MAAS_FIX_TENANT:=true}"           # 63-maas-fixes: 3.4 default-tenant gatewayRef → maas-default-gateway(API Keys 404 해결)
: "${MAAS_ENVOYFILTERS:=true}"         # 63-maas-fixes: health check 차단·ratelimit timeout 2s EnvoyFilter(토큰 한도 미동작 해결)
: "${MAAS_REDIS:=true}"                # 63-maas-fixes: Limitador redis-cached 저장소(Redis Pod 1개)
: "${REDIS_IMAGE:=registry.redhat.io/rhel9/redis-7:latest}"   # 반입 후 digest로 고정 권장
: "${FEATURE_MLFLOW_INSTANCE:=true}"   # 64-mlflow: MLflow 인스턴스(SQLite + PVC). FEATURE_MLFLOW=true일 때만
: "${MLFLOW_STORAGE_SIZE:=10Gi}"
: "${FEATURE_EVALHUB:=true}"           # 65-evalhub: EvalHub CR(SQLite). tokenizer는 HuggingFace 대신 내부 S3·PVC 경로 사용
: "${EVALHUB_NS:=redhat-ods-applications}"   # Dashboard eval-hub-ui가 이 namespace만 조회(RHOAI 3.4)
: "${FEATURE_MCP_SERVERS:=true}"       # 71-mcp-servers: Kubernetes MCP 서버(읽기 전용) + Playground MCP 목록 ConfigMap
: "${MCP_NS:=mcp-servers}"
: "${MCP_SERVER_IMAGE:=quay.io/redhat-ai-services/kubernetes-mcp-server:latest}"
: "${MCP_CLUSTER_ROLE:=view}"          # MCP 서버 ServiceAccount 권한(읽기 전용)

# ------------------------------------------------------------------ 작업계획서 공통·HTTP/2·검증·OTel·3.5.1 업그레이드
#   값 설명은 config/env.bc.sh 참고. 아래는 config/env.sh에 없을 때 쓰는 기본값이다.
: "${WORK_ROOT:=/data/ocp/202611}"
: "${BACKUP_DIR:=/data/backup/202611}"
: "${DSC_NAME:=default-dsc}"
: "${DASH_NAME:=odh-dashboard-config}"
: "${AI_NS:=redhat-ods-applications}"
: "${MIRROR_DIR:=}"
: "${FEATURE_MIRROR_DIR:=}"
: "${MIRROR_SUFFIX:=-202611}"
: "${GPU_MCPS:=}"
: "${H2_ROUTES:=}"
: "${H2_CERT:=${WORK_ROOT}/certs/h2.crt}"
: "${H2_KEY:=${WORK_ROOT}/certs/h2.key}"
: "${H2_CA:=${WORK_ROOT}/certs/h2-ca-chain.pem}"
: "${RHCL_STARTING_CSV:=}"
: "${RHCL_DEPS:=authorino-operator limitador-operator dns-operator}"
: "${RHCL_DEPS_CHANNEL:=stable}"
: "${MAAS_CA_FILE:=}"
: "${MODEL_NS:=model-test}"
: "${MODEL_NAME:=}"
: "${S3_CONNECTION:=vllm-no-otel}"
: "${MAAS_TEST_USER:=}"
: "${MAAS_TEST_GROUP:=maas-test}"
: "${MAAS_TEST_LIMIT:=20000}"
: "${KEYS_FILE:=${WORK_ROOT}/keys.sh}"
: "${PROD_NS:=llm-models}"
: "${TEMPO_NS:=tempo}"
: "${TEMPO_STACK:=sample}"
: "${TEMPO_TENANT:=llm-models}"
: "${TEMPO_TENANT_ID:=22222222-2222-2222-2222-222222222222}"
: "${TEMPO_STORAGE_SIZE:=10Gi}"
: "${TEMPO_S3_CA_FILE:=}"
: "${OTEL_MODELS:=}"
: "${OTEL_LLM_MODELS:=}"
: "${OTEL_TEST_MODELS:=}"
: "${OTEL_TEST_LLM_MODELS:=}"
: "${OTEL_PYTHON_IMAGE:=}"
: "${INSTRUMENTATION_NAME:=vllm-instrumentation}"
: "${OTEL_SAMPLE_RATIO:=0.1}"
: "${PROD_OTLP_BASE:=http://llm-otel-collector.${PROD_NS}.svc.cluster.local:4318}"
: "${RHOAI351_CATALOG:=}"
: "${RHOAI351_CHANNEL:=stable-3.5}"
: "${RHOAI351_CSV:=rhods-operator.3.5.1}"
: "${RHOAI351_MIRROR_DIR:=}"

# ------------------------------------------------------------------ 실행 제어 (보통 명령줄에서 지정)
: "${STEPWISE:=false}"                 # 30-dashboard: 필드를 하나씩 적용하고 브라우저 확인 대기
: "${RESTART_KSERVE_CONTROLLERS:=true}" # 60-rhcl: RHCL 구성 후 odh-model-controller·kserve-controller-manager 재시작
# 아래 *_ACK는 사전 확인을 마쳤다는 표시다. 해당 작업 직전에만 명령줄에서 true로 준다.
: "${KUEUE_MIGRATION_ACK:=false}"      # 내장 Kueue(Managed) → RHBoK(Unmanaged) migration 완료
: "${AUTHORINO_DUP_ACK:=false}"        # kuadrant-system 외 Authorino CR 사용 여부 확인 완료(TS-19)
: "${GENAI_OGX_MIGRATION_ACK:=false}"  # 3.5.1: LlamaStackDistribution 백업 후 OGX 전환 허용
# 41-hardware-profile 값은 HWP_NAME, HWP_DISPLAY_NAME, HWP_GPU_MAX, HWP_CPU_MAX, HWP_MEM_MAX,
# HWP_NODE_SELECTOR_KEY, HWP_NODE_SELECTOR_VALUE 로 바꿀 수 있다(기본값은 스크립트 상단).
