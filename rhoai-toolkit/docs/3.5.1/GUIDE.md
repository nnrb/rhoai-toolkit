# RHOAI 3.5.1 폐쇄망 기능 활성화 가이드

대상: OpenShift 4.19.9+/4.20/4.21/4.22(llm-d는 4.20 이상), `rhods-operator.3.5.1`, 미러 레지스트리 사용 폐쇄망.
3.5는 **EUS 릴리스**다(3.5.1 = 2026년 9월 보안 업데이트, Full Support 종료 2027-03-27). 단, OGX는 EUS 기간 지원에서 제외된다.

실행 절차와 스크립트는 3.4.2와 같다. 이 문서는 **3.4.2와 다른 점**을 중심으로 쓴다. 공통 절차는 [3.4.2 가이드](../3.4.2/GUIDE.md) 3절을 함께 본다.

> 3.5.1 항목은 공식 문서·제품 소스 기준이며 BC 클러스터 실측 전이다. 스크립트는 `oc explain`으로 필드를 확인한 뒤 적용하므로, 처음 실행할 때는 반드시 dry-run 결과의 "스키마에 없는 필드라 건너뜁니다" 경고를 검토한다.

## 0. 3.4.2 대비 변경점

| 항목 | 3.4.2 | 3.5.1 | 영향 |
| --- | --- | --- | --- |
| MaaS 컴포넌트 | `kserve.modelsAsService` | **`aigateway.managementState` + `aigateway.modelsAsAService`** | 구 경로는 deprecated. Removed→Managed 전환을 CEL이 막는다 |
| MaaS DB Secret | `redhat-ods-applications` | **infra namespace**(기본 `redhat-ai-gateway-infra`) | `62-maas.sh`가 `MaaSTenantConfig/default-tenant`의 `status.infraNamespace`를 읽어 복사 |
| MaaS 부가 기능 | — | Batch Gateway(`aigateway.batchGateway`), 외부 OIDC GA, 테넌트별 Gateway(TP) | `FEATURE_BATCH_GATEWAY` |
| Gen AI 백엔드 | Llama Stack(`llamastackoperator`, LlamaStackDistribution) | **OGX**(`ogx`, OGXServer) | 둘은 동시에 Managed 불가. 기존 LSD는 OGXServer로 재생성 |
| MCP | 메뉴 플래그(DP) | `mcplifecycleoperator` 컴포넌트 + `mcpCatalog`/`mcpRegistry`(TP) | `FEATURE_MCP_LIFECYCLE` |
| KServe | — | `modelCache`(노드 로컬 캐시), `enableLLMInferenceServiceTLS`(기본 on) | `FEATURE_MODEL_CACHE` |
| Kueue DSC | 큐 이름 | `autoCreateQueues`(기본 false) 추가 | 툴킷은 큐를 직접 만든다 |
| Spark | TP | GA | — |
| EvalHub | TP | 지원표 TP / 릴리스노트 GA | 지원 범위는 지원 구성표 우선 |
| Dashboard | — | 플래그 14개 추가(agent*, toolCalling, guardrails, gpuaas, roleManagement, connectionTest, llmdTemplates, globalProjectPrompts, featureStoreAdmin, genAiTracing, externalModels, mcpRegistry) | 버전 파일 |
| 사용 안 함 | `mlflow` 등 | + `maasAuthPolicies`, `disableHardwareProfiles` | `DASHBOARD_FORBIDDEN` |
| 기본값 변경 | `modelAsService: false`(문서) | `modelAsService`·`roleManagement`·`gpuaas`·`observabilityDashboard: true` | 백엔드 전에도 MaaS 메뉴가 보일 수 있음 |
| RHCL | 1.3.x | 1.4.x(1.4.0·1.4.1 알려진 문제) → **1.4.2 이상** | `10-operators.sh`가 차단·경고 |
| RHBoK | 1.3 | 1.3 유지(Trainer 비호환). **OCP 4.22 카탈로그에는 1.3 없음** | OCP 4.22에서 Trainer를 쓰면 지원 확인 필요 |
| LWS | llm-d 필수 | multi-node llm-d(서버당 가속기 8개 초과)에만 필수 | 3.4와 같게 설치 |

## 1. 설정

```bash
cp config/env.example.sh config/env.sh
# RHOAI_VERSION=3.5.1 로 변경
```

3.4.2 가이드 1절의 변수에 더해 다음을 확인한다.

| 변수 | 의미 |
| --- | --- |
| `FEATURE_MCP_LIFECYCLE` | MCP 서버 수명주기 Operator와 MCP 메뉴 |
| `FEATURE_MODEL_CACHE`, `MODEL_CACHE_SIZE`, `MODEL_CACHE_NODE_SELECTOR` | KServe 노드 로컬 모델 캐시(캐시 크기 필수, 노드에 `kserve/localmodel=worker` 라벨이 붙음) |
| `FEATURE_BATCH_GATEWAY` | MaaS Batch API |
| `GENAI_OGX_MIGRATION_ACK` | 기존 LlamaStackDistribution이 있을 때 OGX 전환을 허용 |
| `MAAS_READY_REGEX` | MaaS DSC condition 이름. 기본 `(AIGateway\|ModelsAsAService\|ModelsAsService).*Ready`. 실제 이름을 `oc get dsc -o yaml`로 보고 맞춘다 |

## 2. 실행 순서

3.4.2와 같다.

```bash
./scripts/rhoai-enable.sh preflight
./scripts/rhoai-enable.sh all                                   # dry-run
DRY_RUN=false APPROVE_INSTALLPLAN=true ./scripts/rhoai-enable.sh operators
DRY_RUN=false ./scripts/rhoai-enable.sh dsc observability trusted-ca
DRY_RUN=false ./scripts/rhoai-enable.sh kueue hwprofile llmd
DRY_RUN=false ./scripts/rhoai-enable.sh rhcl maas-db maas
DRY_RUN=false ./scripts/rhoai-enable.sh registry dashboard
DRY_RUN=false ./scripts/rhoai-enable.sh genai-offline          # OGXServer 생성 후
./scripts/rhoai-enable.sh verify
```

### 단계별 3.5.1 차이

| 단계 | 3.5.1에서 달라지는 점 | 확인 |
| --- | --- | --- |
| preflight | `kserve.modelsAsService=Managed`가 남아 있거나 LlamaStackDistribution이 있으면 경고 | 업그레이드 클러스터면 4절 먼저 |
| dsc | `ogx: Managed` + `llamastackoperator: Removed`, `mcplifecycleoperator: Managed`. LSD가 있으면 `GENAI_OGX_MIGRATION_ACK=true` 전까지 Gen AI 항목을 건너뜀. 스키마에 `ogx`가 없으면 Llama Stack 유지 | `oc get dsc default-dsc -o jsonpath='{.spec.components}' \| jq` |
| maas | DSC에 `aigateway` 2개 항목 적용. maas-api와 infra namespace에 `maas-db-config` 복사 후 maas-api 재시작 | `oc get maastenantconfigs -A -o yaml \| grep infraNamespace`, `oc get secret maas-db-config -n redhat-ai-gateway-infra` |
| dashboard | 3절 표의 플래그. `maasAuthPolicies`는 쓰지 않음 | `evidence/*/dashboard.after.json` |
| genai-offline | OGXServer의 env 경로를 스키마에서 찾아 HF 오프라인 env 추가. 경로를 못 찾으면 수동 안내 | OGX 서버 로그에 huggingface.co 접속 시도 없음 |

## 3. 3.5.1 Dashboard 플래그 (툴킷 적용 값)

지원 단계는 3.5 "Customizing the dashboard" 표 기준이다.

| 그룹 | 플래그 | 조건 | 단계 |
| --- | --- | --- | --- |
| 공통 | `disableTracking: true`, `disableModelCatalog`·`disableKServeMetrics`·`disablePerformanceMetrics`·`disableDistributedWorkloads: false`, `roleManagement: true` | 항상 | GA |
| 기능 | `disableModelRegistry`·`disableModelRegistrySecureDB`·`disablePipelines`·`disableFeatureStore`·`disableNIMModelServing`·`disableLLMd`·`disableLMEval: false`, `trainingJobs`·`observabilityDashboard`·`gpuaas: true` | 해당 FEATURE | GA(일부 기본 true) |
| Gen AI | `genAiStudio`, `aiAssetCustomEndpoints: true` | GENAI | TP |
| TP | `projectRBAC`, `connectionTest`, `deploymentWizardYAMLViewer`, `toolCalling`, `guardrails`, `externalModels`, `externalVectorStores`, `genAiTracing`, `mcpCatalog`, `mcpRegistry`, `llmGatewayField`, `llmdTemplates`, `featureStoreAdmin`, `automl`, `autorag`, `promptManagement`, `globalProjectPrompts` | PREVIEW + 해당 FEATURE | TP |
| DP | `disableKueue: false`, `agentsCatalog`, `agentOps`, `agentConfigManagement` | DEV_PREVIEW | DP |
| MaaS(62) | `modelAsService`, `vLLMDeploymentOnMaaS: true` | MAAS | GA / TP |
| 쓰지 않음 | `disableTrustyBiasMetrics`, `mlflow`, `maasAuthPolicies`, `disableFineTuning`, `disableHardwareProfiles`, `disableAcceleratorProfiles`, `disableModelMesh` | — | — |

새 최상위 필드 `spec.modelServing.isLLMdDefault`(배포 마법사 기본을 llm-d로), `spec.globalMLflowNamespaces`(전역 프롬프트용 MLflow namespace, 최대 1개)는 운영 정책을 정한 뒤 수동으로 설정한다.

```bash
oc patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications --type=merge \
  -p '{"spec":{"modelServing":{"isLLMdDefault":true}}}' --dry-run=server -o yaml | grep -A3 modelServing
```

## 4. 3.4.x에서 업그레이드한 클러스터

3.5는 3.4 → 3.5, 2.25 → 3.5 직접 업그레이드를 지원한다. 업그레이드 자체는 공식 Upgrading 문서를 따르고, 기능 활성화 전에 다음을 정리한다.

1. **Llama Stack → OGX**: 업그레이드 전에 LlamaStackDistribution 설정을 백업하고 삭제한다. 업그레이드 후 OGXServer로 다시 만든다. 이 툴킷은 LSD가 남아 있으면 `ogx` 전환을 건너뛴다.
   ```bash
   oc get llamastackdistributions -A -o yaml > evidence/lsd-backup.yaml
   ```
2. **MaaS 경로 이관**: `aigateway`를 먼저 켠다(`62-maas.sh`). MaaS가 정상 동작하는 것을 확인한 뒤 구 경로를 끈다. 구 경로는 다시 켤 수 없다.
   ```bash
   oc patch dsc default-dsc --type=merge -p '{"spec":{"components":{"kserve":{"modelsAsService":{"managementState":"Removed"}}}}}' --dry-run=server -o yaml >/dev/null && echo OK
   ```
3. **MaaS DB Secret**: 3.4에서 쓰던 `redhat-ods-applications/maas-db-config`를 infra namespace로 복사한다(`62-maas.sh`가 수행). 같은 DB를 계속 쓰므로 기존 API key가 유지되는지 확인한다.
4. **업그레이드 게이트·채널**: 3.5 업그레이드 확인 항목은 운영자 namespace의 ConfigMap `odh-upgrade-acks`에 기록되고, 남은 항목을 승인해야 구성 요소가 갱신된다(`05-rhoai-upgrade.sh wait`가 내용을 보여 줌). `support-required-upgrade-3.5` 채널은 2.25→3.5 마이그레이션용이며, 그 경우 업그레이드 후 `stable-3.5`(또는 `eus-3.5`)로 옮긴다. BC(3.4.2→3.5.1)는 처음부터 `stable-3.5`를 쓴다.
5. **Dashboard**: 3.4에서 넣은 `maasAuthPolicies`는 3.5 문서에서 "사용하지 않음"으로 표기된다. `30-dashboard.sh`가 CR에 남은 금지 필드를 경고하고 제거 명령을 보여 준다. 제거는 화면 확인 후 선택한다.

## 5. 3.5.1 기능별 후속 작업

3.4.2 가이드 5절에 더해:

| 기능 | 할 일 |
| --- | --- |
| Playground(OGX) | Gen AI Studio에서 Playground 생성 → `genai-offline` 실행 → 모델 추가. RAG는 Milvus 등 vector store와 임베딩 모델 필요 |
| MCP Lifecycle | MCP 서버 이미지를 반입하고 MCP 레지스트리에 등록한 뒤 배포. 도구 호출은 vLLM tool-calling 인자 필요 |
| Agents(DP) | 에이전트 카탈로그 항목의 이미지 반입. 지원 대상 아님 |
| External models(TP) | 폐쇄망에서는 내부 OpenAI 호환 endpoint만 등록. `GENAI_CLUSTER_DOMAINS`에 내부 도메인 추가 |
| Model cache | 캐시 노드 디스크 용량 확인 후 `FEATURE_MODEL_CACHE=true`로 dsc 재실행 |
| MaaS 외부 OIDC(GA) | 사내 IdP 발급자·클라이언트 ID로 MaaS 설정(공식 MaaS 문서) |

## 6. 검증

3.4.2 가이드 6절 검증표(V01~V11)를 그대로 쓰고, 다음을 더한다.

| ID | 시나리오 | 기대 결과 |
| --- | --- | --- |
| V12 | `oc get dsc` aigateway·ogx·mcplifecycleoperator condition | True |
| V13 | 업그레이드 클러스터에서 3.4 시절 발급 API key로 호출 | 200(DB 유지) |
| V14 | OGX Playground 대화·RAG | 응답, HF 접속 시도 없음 |

## 7. 근거

- RHOAI 3.5 문서: Release notes(3.5.1 보안 업데이트), Upgrading(EUS·OGX 전환·업그레이드 ack), Installing in a disconnected environment, Customizing the dashboard, MaaS, llm-d
- Red Hat 지원 구성표(OCP 버전·컴포넌트 지원 단계): https://access.redhat.com/articles/rhoai-supported-configs-3.x
- red-hat-data-services/rhods-operator `rhoai-3.5` 브랜치 `api/datasciencecluster/v2`, `api/components/v1alpha1/kserve_types.go`
- red-hat-data-services/odh-dashboard `rhoai-3.5` 브랜치 OdhDashboardConfig CRD
- red-hat-data-services/rhoai-disconnected-install-helper `rhoai-3.5.1-imagesetconfig.yaml`
- RHOAI-Toolkit: `datasciencecluster-v3-35.yaml`, `3.5-enable-dashboard-features.sh`
