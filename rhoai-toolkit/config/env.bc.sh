# BC카드 폐쇄망 설정(2026-10-28 사전 점검 기준). 모든 스크립트 작업계획서가 이 파일 하나를 쓴다.
#   준비: bash bc-toolkit.sh init  → config/env.sh 생성(권한 600) → "<...>" 값을 현장 값으로 바꾼다.
#   값은 "명령줄 환경변수 > config/env.sh > config/env.example.sh 기본값" 순으로 적용된다.
#   비밀값(키·비밀번호·API key)은 이 파일에 적지 않는다. 스크립트가 실행 중에 입력받는다.

# ------------------------------------------------------------------ 공통
: "${RHOAI_VERSION:=3.4.2}"            # 05 작업계획서(3.5.1 업그레이드) 8단계부터 3.5.1
: "${DRY_RUN:=true}"                   # 명령줄에서 DRY_RUN=false 로 줄 때만 실제 적용
: "${ASSUME_YES:=false}"
: "${WORK_ROOT:=/data/ocp/202611}"     # 작업 파일·증적 위치
: "${BACKUP_DIR:=/data/backup/202611}" # 사전 백업 경로. 작업계획서별 하위 디렉터리(http2, rhoai342, maas, rhoai351)에 저장
: "${APPS_DOMAIN:=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null)}"
: "${AI_NS:=redhat-ods-applications}"
: "${DSC_NAME:=default-dsc}"
: "${DASH_NAME:=odh-dashboard-config}"

# ------------------------------------------------------------------ 폐쇄망 카탈로그·미러
: "${CATALOG_SOURCE:=cs-redhat-operator-index-ai-other}"          # RHCL·LWS·Kueue·JobSet·COO·OTel·Tempo가 있는 카탈로그
: "${CERTIFIED_CATALOG_SOURCE:=cs-certified-operator-index-nvidia-263}"
: "${INSTALL_PLAN_APPROVAL:=Manual}"
: "${APPROVE_INSTALLPLAN:=false}"
: "${INTERNAL_REGISTRY:=pocprg01.ocp.bcnuri.com:5000}"
: "${MIRROR_DIR:=}"                    # release oc-mirror 결과(01 업그레이드 작업계획서에서 수동 적용 → 여기서는 비움)
: "${FEATURE_MIRROR_DIR:=<imageset-02 oc-mirror 결과 디렉터리>}"   # 03 작업계획서: RHOAI 3.4.2 기능·스크립트 실행용 이미지
: "${MIRROR_SUFFIX:=-202611}"          # oc-mirror 결과 IDMS/ITMS 이름에 붙이는 접미사(기존 객체 덮어쓰기 방지). 3.5.1 반입분은 -rhoai351
: "${GPU_MCPS:=worker-temp worker}"    # GPU worker MCP(미러 적용 전 pause 여부 확인)

# ------------------------------------------------------------------ 클러스터 값
: "${STORAGE_CLASS:=ontap-iscsi}"      # DB용 블록 스토리지
: "${INTERNAL_CA_FILE:=}"              # 사내 CA(BCC Sub CA 체인) PEM. 내부 S3·레지스트리·DB TLS에 필요하면 지정
: "${MODEL_NAMESPACES:=model-test}"    # MaaS Gateway 접근 label 대상

# ------------------------------------------------------------------ 기능 선택(2026-10-28 DSC 상태 기준)
: "${FEATURE_WORKBENCHES:=true}"
: "${FEATURE_PIPELINES:=true}"
: "${FEATURE_KSERVE:=true}"
: "${FEATURE_MODEL_REGISTRY:=true}"
: "${FEATURE_MLFLOW:=true}"
: "${FEATURE_FEAST:=true}"
: "${FEATURE_GENAI:=true}"             # 3.5.1: Llama Stack → OGX 전환 주의(GENAI_OGX_MIGRATION_ACK)
: "${FEATURE_RAY:=true}"
: "${FEATURE_TRAINER:=true}"           # jobset-operator 1.0.0 설치됨
: "${FEATURE_TRAINING_OPERATOR:=true}" # 현재 Managed(deprecated, 2027-03-27 EOL). 사용 Job 정리 후 false
: "${FEATURE_TRUSTYAI:=true}"
: "${FEATURE_SPARK:=true}"
: "${FEATURE_KUEUE:=false}"            # RHBoK 미설치, DSC kueue=Removed. 도입 결정 시 true(RHBoK 1.3)
: "${FEATURE_MAAS:=true}"
: "${FEATURE_LLMD:=true}"
: "${FEATURE_NIM:=false}"              # NGC 이미지 미반입
: "${FEATURE_WVA:=false}"
: "${FEATURE_MCP_LIFECYCLE:=true}"     # 3.5.1 이상
: "${FEATURE_OBSERVABILITY:=true}"     # COO·OTel·Tempo 설치됨
: "${FEATURE_GPU:=false}"              # NFD·GPU Operator 26.3.3 설치됨
: "${FEATURE_MODEL_CACHE:=false}"
: "${FEATURE_BATCH_GATEWAY:=false}"
: "${FEATURE_PREVIEW:=true}"
: "${FEATURE_DEV_PREVIEW:=true}"
: "${FEATURE_OBS_UI:=true}"
: "${FEATURE_MLFLOW_INSTANCE:=true}"
: "${FEATURE_EVALHUB:=true}"
: "${FEATURE_MCP_SERVERS:=true}"       # kubernetes-mcp-server 반입 전에는 false

: "${JOBSET_PACKAGE:=job-set}"
: "${JOBSET_NS:=openshift-jobset-operator}"

# ------------------------------------------------------------------ Kueue(FEATURE_KUEUE=true일 때)
: "${KUEUE_QUEUE_NAME:=default}"
: "${KUEUE_NAMESPACES:=}"
: "${GPU_RESOURCE_NAME:=nvidia.com/gpu}" # MIG 노드(paixap01)는 nvidia.com/mig-3g.71gb, nvidia.com/mig-4g.71gb

# ------------------------------------------------------------------ [02] HTTP/2
: "${H2_ROUTES:=<인증서를 바꿀 기존 Route: ns/route 공백 구분, 테스트 도메인 Route를 맨 앞>}"
: "${H2_CERT:=${WORK_ROOT}/certs/h2.crt}"          # 와일드카드(*.도메인) 또는 개별 인증서. SAN이 H2_ROUTES의 host를 모두 포함
: "${H2_KEY:=${WORK_ROOT}/certs/h2.key}"
: "${H2_CA:=${WORK_ROOT}/certs/h2-ca-chain.pem}"    # 중간 CA + root CA

# ------------------------------------------------------------------ [04] MaaS
: "${RHCL_STARTING_CSV:=rhcl-operator.v1.4.2}"     # 미러 카탈로그 stable 채널의 유일한 버전(2026-10-28)
: "${RHCL_DEPS:=authorino-operator limitador-operator dns-operator}"   # 12-rhcl-deps.sh: 구독을 CATALOG_SOURCE로 맞출 RHCL 의존 Operator
: "${RHCL_DEPS_CHANNEL:=stable}"       # authorino-operator: cs-redhat-operator-index v1.2.2(현재 구독) → ai-other v1.4.2(2026-10-30 확인)
: "${MAAS_DB_MODE:=internal}"
: "${MAAS_DB_NS:=redhat-ods-applications}"
: "${MAAS_DB_IMAGE:=registry.redhat.io/rhel9/postgresql-16@sha256:cb16884277c60ba0e2adfd7d0342eb87e651c0ecdbe8c8471615059b5c722846}"
: "${MAAS_DB_SIZE:=20Gi}"
: "${MAAS_HOSTNAME:=maas.${APPS_DOMAIN}}"
: "${MAAS_TLS_SECRET:=maas-gateway-tls}"
: "${MAAS_TLS_CERT_FILE:=${WORK_ROOT}/certs/maas-fullchain.crt}"   # 서버 인증서 + 중간 CA(SAN=MAAS_HOSTNAME)
: "${MAAS_TLS_KEY_FILE:=${WORK_ROOT}/certs/maas.key}"
: "${MAAS_CA_FILE:=${WORK_ROOT}/certs/maas-ca-chain.pem}"          # 호출 검증용 CA(중간 CA + root CA)
: "${GATEWAY_ACCESS_LABEL:=platform.bcnuri.com/maas-gateway-access}"
: "${RHCL_AUTH_TIMEOUT:=2s}"
: "${MAAS_FIX_TENANT:=true}"
: "${MAAS_ENVOYFILTERS:=true}"
: "${MAAS_REDIS:=true}"                # redis-7 반입 전에는 false(./bc-toolkit.sh images로 확인)

# ------------------------------------------------------------------ [04] llm-d·MaaS 검증
: "${LLMD_STANDALONE_GATEWAY:=false}"  # BC는 MaaS Gateway로 llm-d 모델을 공개. 별도 inference Gateway 미생성
: "${MODEL_NS:=model-test}"
: "${MODEL_NAME:=maas-test-llm}"       # Dashboard에서 llm-d로 배포하는 검증 모델 이름
: "${S3_CONNECTION:=vllm-no-otel}"     # 검증 모델 파일 S3 Connection(없으면 76-llmd-test.sh s3conn이 입력받아 생성)
: "${MAAS_TEST_USER:=<MaaS 테스트에 쓸 기존 사용자(Dashboard 로그인 가능)>}"
: "${MAAS_TEST_GROUP:=maas-test}"
: "${MAAS_TEST_LIMIT:=20000}"          # 분당 token 한도(시험 중 300으로 임시 축소 후 원복)
: "${KEYS_FILE:=${WORK_ROOT}/keys.sh}" # API key 보관 파일(권한 600, 작업 후 삭제)

# ------------------------------------------------------------------ [04] OpenTelemetry·Tempo
: "${PROD_NS:=llm-models}"
: "${TEMPO_NS:=tempo}"
: "${TEMPO_STACK:=sample}"
: "${TEMPO_TENANT:=llm-models}"
: "${TEMPO_TENANT_ID:=22222222-2222-2222-2222-222222222222}"
: "${TEMPO_STORAGE_SIZE:=10Gi}"
: "${TEMPO_S3_CA_FILE:=}"               # Tempo S3가 사내 CA로 서명된 https이면 CA PEM 경로(http면 비움)
: "${OTEL_MODELS:=<OTel 적용 대상 운영 InferenceService 이름(공백 구분, 없으면 빈 값)>}"
: "${OTEL_LLM_MODELS:=}"
: "${OTEL_TEST_MODELS:=}"
: "${OTEL_TEST_LLM_MODELS:=${MODEL_NAME}}"
: "${OTEL_PYTHON_IMAGE:=${INTERNAL_REGISTRY}/rhoai342-202611/open-telemetry/opentelemetry-operator/autoinstrumentation-python:0.54b1}"
: "${INSTRUMENTATION_NAME:=vllm-instrumentation-202611}"
: "${OTEL_SAMPLE_RATIO:=0.1}"
: "${PROD_OTLP_BASE:=http://llm-otel-collector.${PROD_NS}.svc.cluster.local:4318}"

# ------------------------------------------------------------------ [05] RHOAI 3.5.1 업그레이드
: "${RHOAI351_CATALOG:=<imageset-03 반입으로 만든 CatalogSource 이름>}"
: "${RHOAI351_CHANNEL:=stable-3.5}"
: "${RHOAI351_CSV:=rhods-operator.3.5.1}"
: "${RHOAI351_MIRROR_DIR:=/data/mirror/rhoai351}"   # imageset-03 oc-mirror 결과(10-mirror-apply.sh MIRROR_PROFILE=rhoai351)

# ------------------------------------------------------------------ Model Registry(rhoai-model-registries에 이미 있음)
: "${MR_NS:=rhoai-model-registries}"
: "${MR_DB_HOST:=}"                    # 비워 두면 인스턴스 생성 단계를 건너뜀

# ------------------------------------------------------------------ Gen AI 폐쇄망
: "${GENAI_CLUSTER_DOMAINS:=svc.cluster.local,apps.ocp.bcnuri.com}"
: "${GENAI_EXTERNAL_PROVIDERS:=false}"

# ------------------------------------------------------------------ 관측(DSCI monitoring, RHOAI 통합 관측. 04의 TempoStack과 별개)
: "${TRACES_BACKEND:=pv}"
: "${TRACES_S3_SECRET:=}"
