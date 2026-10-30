# 기능 매트릭스 — RHOAI 3.4.2 / 3.5.1 (폐쇄망)

활성화할 수 있는 기능 전체를 한 표로 정리했다. 각 기능은 네 겹으로 켜진다. 오퍼레이터 → DSC 컴포넌트 → 인스턴스·인프라 → Dashboard 플래그. 마지막 열은 폐쇄망에서 추가로 반입해야 하는 것이다.

- 지원 단계: GA / TP(Technology Preview) / DP(Developer Preview). Red Hat 지원 구성표와 각 버전의 "Customizing the dashboard" 표 기준이다.
- 스크립트 열의 번호는 `scripts/` 파일 번호다.
- `FEATURE_*`는 `config/env.sh`의 기능 선택 변수다.

## 1. 플랫폼·개발

| 기능 | FEATURE | DSC 컴포넌트 | 의존 오퍼레이터 | Dashboard 플래그 | 3.4.2 | 3.5.1 | 스크립트 | 폐쇄망 반입 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Dashboard | — | `dashboard` | — | `disableTracking: true` | GA | GA | 20, 30 | — |
| Workbench | WORKBENCHES | `workbenches` | — | `notebookController` | GA | GA | 20 | Workbench 이미지(mirror/ additionalImages) |
| Hardware Profile | — | — | (GPU: NFD·GPU Operator) | — | GA | GA | 41 | — |
| Kueue 대기열 | KUEUE | `kueue: Unmanaged` | RHBoK 1.3, cert-manager | `disableKueue: false` | GA(플래그 기본 true) | 플래그 DP | 10, 20, 40 | — |
| GPU as a Service | KUEUE | — | RHBoK | `gpuaas` | — | 기본 true | 30 | — |
| 프로젝트 RBAC 확장 | PREVIEW | — | — | `projectRBAC` | TP | 기본 true | 30 | — |
| Role 관리 | — | — | — | `roleManagement` | — | 기본 true | 30 | — |
| 연결 테스트 | PREVIEW | — | — | `connectionTest` | — | TP | 30 | — |
| 사내 CA 신뢰 | — | DSCI `trustedCABundle` | — | — | GA | GA | 22 | 사내 CA PEM |

## 2. 데이터·학습

| 기능 | FEATURE | DSC 컴포넌트 | 의존 오퍼레이터 | Dashboard 플래그 | 3.4.2 | 3.5.1 | 스크립트 | 폐쇄망 반입 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| AI Pipelines | PIPELINES | `aipipelines` | — | `disablePipelines: false` | GA | GA | 20, 30 | pipeline runtime 이미지, 내부 S3 |
| AutoML / AutoRAG | PREVIEW+PIPELINES | `aipipelines` | — | `automl`, `autorag` | TP | TP | 30 | pipelines-components Git 저장소·PyPI 미러(RHOAIENG-59340) |
| Feature Store (Feast) | FEAST | `feastoperator` | — | `disableFeatureStore: false`, `featureStoreAdmin`(3.5 TP) | GA | GA | 20, 30 | Feast 이미지·내부 Git |
| Spark | SPARK | `sparkoperator` | — | — | TP | GA | 20 | Spark 이미지 |
| Ray (KubeRay) | RAY | `ray` | RHBoK, cert-manager | — | GA | GA | 10, 20 | Ray 이미지(additionalImages) |
| Trainer v2 | TRAINER | `trainer` | JobSet, RHBoK **1.3** | `trainingJobs` | GA | GA | 10, 20, 30 | 학습 runtime 이미지(odh-th06 등) |
| Training Operator v1 | TRAINING_OPERATOR | `trainingoperator` | RHBoK | — | Deprecated | Deprecated(2027-03-27 EOL) | 20 | — |
| MLflow | MLFLOW | `mlflowoperator` | — | (플래그 불필요) | GA | GA | 20 | 내부 DB·S3 |
| 프롬프트 관리 | PREVIEW+MLFLOW | — | — | `promptManagement`, `globalProjectPrompts`(3.5) | TP | TP | 30 | MLflow 인스턴스 |

## 3. 모델 서빙·관리

| 기능 | FEATURE | DSC 컴포넌트 | 의존 오퍼레이터 | Dashboard 플래그 | 3.4.2 | 3.5.1 | 스크립트 | 폐쇄망 반입 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| KServe (vLLM 등) | KSERVE | `kserve` (RawDeployment) | cert-manager | `disableKServeMetrics`, `disablePerformanceMetrics: false` | GA | GA | 20, 30 | 런타임은 CSV relatedImages로 반입, 모델은 내부 S3/PVC/OCI |
| llm-d 분산 추론 | LLMD | `kserve` | cert-manager, LWS, RHCL, **OCP 4.20+** | `disableLLMd: false`, `llmGatewayField`, `deploymentWizardYAMLViewer`, `llmdTemplates`(3.5) | GA | GA | 10, 50, 30 | 모델 아티팩트 |
| WVA 자동 확장 | WVA | `kserve.wva` | — | — | TP | TP | 20 | — |
| 노드 로컬 모델 캐시 | MODEL_CACHE | `kserve.modelCache` | — | — | — | 신규 | 20 | — |
| NVIDIA NIM | NIM | `kserve.nim` (`airGapped: true`) | GPU Operator | `disableNIMModelServing: false` | GA | GA | 20, 30 | NIM 이미지·모델 캐시 |
| Model Registry | MODEL_REGISTRY | `modelregistry` | — | `disableModelRegistry`, `disableModelRegistrySecureDB: false` | GA | GA | 20, 30, 70 | 외부 DB(MySQL 8 권장 / BC는 PostgreSQL 16) |
| Model Catalog | — | `modelregistry` | — | `disableModelCatalog: false` | GA | GA | 30, 70 | 카탈로그 메타는 로컬, 배포 시 modelcar 반입 |

## 4. 생성형 AI

| 기능 | FEATURE | DSC 컴포넌트 | 의존 오퍼레이터 | Dashboard 플래그 | 3.4.2 | 3.5.1 | 스크립트 | 폐쇄망 반입 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Gen AI Studio·Playground | GENAI | 3.4 `llamastackoperator` / 3.5 `ogx` | Service Mesh 3, cert-manager, GPU | `genAiStudio` | TP | TP | 20, 30, 72 | HF 오프라인 env(72) |
| 사용자 정의 endpoint | GENAI | — | — | `aiAssetCustomEndpoints`, `genAiStudioConfig.aiAssetCustomEndpoints.*` | 문서 표기 없음 | TP | 30 | 내부 도메인 허용 목록(`GENAI_CLUSTER_DOMAINS`) |
| 외부 모델 등록 | PREVIEW+GENAI | — | — | `externalModels` | — | TP | 30 | 내부 OpenAI 호환 endpoint만 |
| Tool calling / Guardrails | PREVIEW+GENAI | `trustyai` | — | `toolCalling`, `guardrails` | — | TP | 30 | Guardrails 모델 |
| 외부 vector store (RAG) | DEV_PREVIEW(3.4) / PREVIEW(3.5) | — | — | `externalVectorStores` | DP | TP | 30 | Milvus 등 |
| MCP 카탈로그·레지스트리 | DEV_PREVIEW(3.4) / MCP_LIFECYCLE(3.5) | 3.5 `mcplifecycleoperator` | — | `mcpCatalog`, `mcpRegistry`(3.5) | DP | TP | 20, 30 | MCP 서버 이미지 |
| Agent 카탈로그·Ops·설정 | DEV_PREVIEW | — | — | `agentsCatalog`, `agentOps`, `agentConfigManagement` | — | DP | 30 | 에이전트 이미지 |
| Gen AI tracing | PREVIEW+OBSERVABILITY | — | OTel·Tempo | `genAiTracing` | — | TP | 30 | — |

## 5. MaaS·평가·관측

| 기능 | FEATURE | DSC 컴포넌트 | 의존 오퍼레이터 | Dashboard 플래그 | 3.4.2 | 3.5.1 | 스크립트 | 폐쇄망 반입 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Models-as-a-Service | MAAS | 3.4 `kserve.modelsAsService` / 3.5 `aigateway.modelsAsAService` | RHCL(3.4: 1.3+, 3.5: 1.4.2+), cert-manager, UWM, PostgreSQL 14+ | `modelAsService`, `maasAuthPolicies`(3.4만), `vLLMDeploymentOnMaaS`(TP) | GA | GA | 10, 60, 61, 62 | PostgreSQL 이미지, 서버 인증서 |
| MaaS Batch API | BATCH_GATEWAY | 3.5 `aigateway.batchGateway` | — | — | — | 신규 | 62 | — |
| TrustyAI bias/drift | TRUSTYAI | `trustyai` | — | (`disableTrustyBiasMetrics` 명시 금지) | GA | GA | 20 | — |
| LM-Eval / EvalHub | TRUSTYAI | `trustyai` (`lmeval permit*: deny`) | — | `disableLMEval: false` | TP | TP(지원표)/GA(릴리스노트) | 20, 30 | 평가 이미지·데이터셋 |
| 통합 관측 대시보드 | OBSERVABILITY | DSCI `monitoring` | COO, OTel, Tempo, UWM | `observabilityDashboard` | TP | 기본 true | 10, 21, 30 | — |

## 6. 3.4.2 → 3.5.1 핵심 변경

| 항목 | 3.4.2 | 3.5.1 | 툴킷 처리 |
| --- | --- | --- | --- |
| MaaS DSC 경로 | `kserve.modelsAsService` | `aigateway.modelsAsAService` (구 경로 deprecated, Removed→Managed 불가) | 버전 파일 `MAAS_DSC_ITEMS` |
| MaaS DB Secret 위치 | `redhat-ods-applications` | infra namespace(기본 `redhat-ai-gateway-infra`, `MaaSTenantConfig.status.infraNamespace`) | 62가 자동 복사 |
| Gen AI 백엔드 | `llamastackoperator`(LlamaStackDistribution) | `ogx`(OGXServer). 동시 Managed 불가 | 3.5.1 `version_dsc_guard`, `GENAI_OGX_MIGRATION_ACK` |
| MCP | Dashboard 플래그만 | `mcplifecycleoperator` 컴포넌트 추가 | FEATURE_MCP_LIFECYCLE |
| Spark | TP | GA | — |
| Kueue DSC | 큐 이름 2개 | `autoCreateQueues` 추가(기본 false) | 40이 큐 직접 생성 |
| Dashboard 플래그(CRD 기준) | 53개 | +14개(agent*, toolCalling, guardrails, gpuaas 등) | 버전 파일 |
| 사용 안 하는 플래그 | `mlflow`, `disableFineTuning` 등 | + `maasAuthPolicies`, `disableHardwareProfiles` | `DASHBOARD_FORBIDDEN` |
| RHCL | 1.3.x 문서 기준 | 1.4.x(1.4.0·1.4.1 알려진 문제) | 10이 버전 차단·경고 |
| 릴리스 성격 | 일반 | EUS(OGX는 EUS 기간 지원 제외) | — |

## 7. 이 표의 근거와 한계

- 3.4.2 행은 BC 클러스터 실측(`oc explain`, 2026-09-15~29)과 3.4 문서 기준이다.
- 3.5.1 행은 3.5 공식 문서, rhods-operator·odh-dashboard `rhoai-3.5` 브랜치 코드, RHOAI-Toolkit 3.5 스크립트 기준이며 **클러스터 실측 전**이다. 스크립트가 스키마 필터로 없는 필드를 건너뛰므로, 실제 적용 결과(`evidence/*/dashboard.after.json`)로 이 표를 갱신한다.
- 지원 단계는 문서 간에 다른 경우가 있다(예: EvalHub, `disableKueue`). 지원 범위 판단은 Red Hat 지원 구성표를 우선한다.
