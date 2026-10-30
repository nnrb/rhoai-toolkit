# 트러블슈팅

RHOAI 3.4.2 폐쇄망(BC 테스트 클러스터, 2026-09-29 ~ 10-06)에서 MaaS·llm-d를 구성하며 겪은 문제를 요약했다. 전체 기록은 `RHOAI가능활성화/rhoai-toolkit-guides/21-maas-llmd-troubleshooting.ko.md`에 있다. 3.5.1에서도 같은 구성 요소(RHCL·Gateway·Authorino)를 쓰므로 먼저 이 표를 확인한다.

스크립트에 반영한 항목은 "반영" 열에 해당 스크립트를 적었다.

| ID | 증상 | 원인 | 조치 | 반영 |
| --- | --- | --- | --- | --- |
| TS-01 | maas-api CrashLoopBackOff, `server refused TLS connection` | 클러스터 내 PostgreSQL은 TLS 미사용인데 접속 URL이 TLS 요구 | `sslmode=disable`로 `maas-db-config` 재생성 후 `oc rollout restart deploy/maas-api` | 61-maas-db.sh |
| TS-02 | `maas.<도메인>` 호출 시 router 503 "Application is not available" | Route가 Gateway Service를 가리키지 않음 | Route `to.name`이 `<gateway>-<gatewayclass>` Service인지 확인 | manifests/gateway |
| TS-03 | Gateway가 다른 hostname의 인증서를 제시 | listener에 hostname·인증서 미지정 또는 SAN 불일치 | MaaS 전용 인증서(SAN=`maas.<도메인>`)를 listener에 지정 | 62-maas.sh |
| TS-04 | `oc whoami -t` 실패 | 인증서(kubeconfig) 로그인은 토큰이 없음 | 사용자 계정으로 `oc login` 후 토큰 사용 | 62-maas.sh 경고 |
| TS-05 | API key 검증 실패, Authorino에 CA env만 있고 파일 없음 | `SSL_CERT_FILE`만 설정하고 service CA 볼륨 미마운트 | Authorino CR `spec.volumes`로 CA ConfigMap 마운트 | 60-rhcl.sh |
| TS-06 | `/maas-api/v1/models` 500, Gateway 로그 `xds-grpc ... x509` | Gateway Envoy가 istiod와 TLS 연결 실패 | Gateway Pod 재생성, istiod CA 확인 | — |
| TS-07 | 정책 `Enforced=False (not in the path to any existing routes)` | HTTPRoute status 갱신 경합 | 정책·Route 재조정 대기, 지속 시 지원 케이스 | — |
| TS-08 | Subscription·AuthPolicy `Failed`, `SpecPriorityDuplicate` | 모델 미존재 또는 같은 priority | 모델 배포 후 재확인, priority 분리 | samples 주석 |
| TS-09 | API key 화면 "No subscriptions available" | 사용자 그룹에 맞는 Subscription 없음 | 그룹·Subscription 확인 | — |
| TS-10 | 기존 vLLM InferenceService를 MaaS에 연결 불가 | MaaS는 LLMInferenceService만 지원 | llm-d(LLMInferenceService)로 재배포 | GUIDE |
| TS-11 | Dashboard에 LLMInferenceServiceConfig 생성 화면 없음 | UI 미제공 | CLI로 생성 | GUIDE |
| TS-12 | vLLM `Free memory on device` | GPU 공유(time-slicing) 시 메모리 부족 | `--gpu-memory-utilization` 하향 | samples |
| TS-13 | Subscription이 계속 `Failed` | MaaSModelRef 이름과 배포 이름 불일치 | 이름 일치 | samples 주석 |
| TS-14 | API key 호출 403 `PERMISSION_DENIED` | AuthPolicy 누락·불일치 | Subscription과 AuthPolicy가 같은 모델 참조 | samples 주석 |
| TS-15 | vLLM 엔진 종료 `illegal memory access` | compute capability 8 미만 GPU의 attention backend | `VLLM_ATTENTION_BACKEND=TRITON_ATTN` | — |
| TS-16 | LLMInferenceService patch 시 webhook timeout | webhook Pod 지연 | 재시도, webhook Pod 상태 확인 | — |
| TS-17 | 재부팅 후 `password authentication failed for user "maas"` | PVC가 데이터 디렉터리에 마운트되지 않아 DB 초기화 / 비밀번호 재생성 | PVC를 `/var/lib/pgsql/data`에 마운트, 기존 Secret 비밀번호 유지 | postgresql.yaml, 61-maas-db.sh |
| TS-18 | 재부팅 후 GPU Pod `UnexpectedAdmissionError` | 디바이스 플러그인보다 먼저 스케줄 | 실패 Pod 삭제 후 재생성 | — |
| TS-19 | API Keys 탭 오류, 토큰·key 모두 401 `tokenreviews ... forbidden` | 이름이 같은 Authorino CR 2개가 ClusterRoleBinding 공유 | 미사용 Authorino CR 삭제 후 operator·Authorino 재시작 | 00-preflight, 60-rhcl.sh |
| TS-20 | 재부팅 후 Dashboard 504, `kuadrant-wasm-shim failed to load` | Gateway가 kuadrant-operator보다 먼저 기동해 Wasm 로드 실패(fail-closed) | 해당 Gateway Pod 재생성 | 90-verify.sh |

## 재부팅 후 점검 순서

```bash
./scripts/rhoai-enable.sh verify
```

1. DSC condition에 False가 없는지 본다.
2. `Authorino tokenreviews 권한`이 `yes`인지 본다. 아니면 TS-19.
3. Gateway Wasm 통계에서 `fetch_failures`가 있고 `successes`가 0인 Gateway는 kuadrant-operator가 Ready인지 확인한 뒤 Pod를 재생성한다(TS-20).
4. maas-postgresql·maas-api가 Ready인지 본다. DB 인증 오류면 TS-17.
5. GPU 모델 Pod가 `Failed`로 남아 있으면 삭제해 재생성한다(TS-18).

## 폐쇄망 공통 확인

| 증상 | 확인 |
| --- | --- |
| Pod `ImagePullBackOff` | `oc get pod <pod> -o jsonpath='{..image}'`의 digest가 IDMS 미러 대상인지, `mirror/` ImageSetConfiguration에 해당 이미지가 있는지 |
| Subscription이 InstallPlan을 만들지 않음 | `oc get catalogsource -n openshift-marketplace` READY 여부, 패키지·채널 존재(`oc get packagemanifests -l catalog=<CS>`) |
| GatewayClass `Accepted: Unknown` | Service Mesh 3를 수동 구독했는지, OCP가 만든 `servicemeshoperator3` 구독의 source 카탈로그가 미러에 있는지 |
| 기능 메뉴는 보이는데 동작하지 않음 | 해당 기능의 백엔드 이미지(MCP 서버, EvalHub, NIM 등)가 반입됐는지. 메뉴 플래그는 백엔드를 설치하지 않는다 |
| 모델 다운로드 실패 | `hf://`·외부 URL 사용 여부. 내부 S3·PVC·내부 레지스트리 modelcar로 바꾼다 |

## RHOAI-Toolkit에서 가져온 단계의 원복

| 단계 | 원복 명령 |
| --- | --- |
| 23-observability-ui | `oc delete uiplugin dashboards monitoring` (이 스크립트가 만든 경우만), `oc delete prometheusrule accelerator-recording-rules -n nvidia-gpu-operator` |
| 63-maas-fixes ① Tenant | `scripts/99-rollback.sh`에 없음 → `evidence/<시각>/backup-tenants.maas.opendatahub.io-default-tenant-models-as-a-service.yaml`의 `spec.gatewayRef`로 `oc patch tenants.maas.opendatahub.io default-tenant -n models-as-a-service --type=merge` |
| 63-maas-fixes ② Redis | `oc patch limitador limitador -n kuadrant-system --type=json -p '[{"op":"remove","path":"/spec/storage"}]'` → `oc delete deploy,svc,networkpolicy limitador-redis -n kuadrant-system`, `oc delete secret limitador-redis-config -n kuadrant-system` (카운터는 초기화됨) |
| 63-maas-fixes ③ EnvoyFilter | `oc delete envoyfilter healthcheck-filter increase-ratelimit-cluster-timeout -n openshift-ingress` → MaaS Gateway Pod 재기동 |
| 64-mlflow | `oc delete mlflows.mlflow.opendatahub.io mlflow` (PVC의 실험 기록도 지워지는지 먼저 확인) |
| 65-evalhub | `oc delete evalhubs.trustyai.opendatahub.io evalhub -n redhat-ods-applications` → `oc rollout restart deploy/rhods-dashboard -n redhat-ods-applications` |
| 71-mcp-servers | `oc patch configmap gen-ai-aa-mcp-servers -n redhat-ods-applications --type=json -p '[{"op":"remove","path":"/data/Kubernetes-MCP-Server"}]'` → `oc delete ns mcp-servers`, `oc delete clusterrolebinding kubernetes-mcp-server-mcp-servers` |

| 증상 | 확인 |
| --- | --- |
| `install`이 "미반입 이미지"로 멈춤 | `./bc-toolkit.sh images` 결과의 이미지를 imageset-02 [S]로 반입하거나 해당 기능 변수를 false |
| API Keys 화면 404(3.4) | `oc get tenants.maas.opendatahub.io default-tenant -n models-as-a-service -o jsonpath='{.spec.gatewayRef}'` → maas-default-gateway여야 함(63-maas-fixes) |
| 토큰 한도를 넘어도 429가 나오지 않음 | EnvoyFilter 2개와 Limitador redis-cached 확인(63-maas-fixes), MaaS Gateway Pod 재기동 여부 |
| RHOAI Observe 대시보드 GPU 패널 No data | `accelerator-recording-rules` 존재, DCGM exporter ServiceMonitor 확인 |
| COO 1.5.0에서 Perses Pod CrashLoop(`-web.tls-min-version`) | COO 1.4.x 유지(Manual 승인) 또는 `data-science-perses` StatefulSet 삭제 후 재생성 |
| EvalHub 메뉴에 인스턴스가 안 보임 | EvalHub가 redhat-ods-applications에 있는지, rhods-dashboard 재기동 여부 |
| EvalHub 평가가 tokenizer 다운로드에서 실패 | 폐쇄망은 HuggingFace 접근 불가 → tokenizer를 내부 S3·PVC에 두고 경로 지정 |
