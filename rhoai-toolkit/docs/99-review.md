# 작성 후 검토 결과 (2026-10-22)

## 1. 검토 방법

| 구분 | 방법 | 결과 |
| --- | --- | --- |
| 출처 대조 | RHOAI-Toolkit(3.4·3.5 스크립트·매니페스트), RHOAI 3.4·3.5 공식 문서, rhods-operator·odh-dashboard `rhoai-3.4`/`rhoai-3.5` 브랜치, Red Hat disconnected helper, ODH MaaS 가이드, BC 3.4.2 실측 문서를 서로 대조 | 불일치 항목은 2절에 기록하고, 버전 파일에 근거를 주석으로 남김 |
| 정적 코드 리뷰 | 독립 리뷰어가 스크립트·설정·템플릿 전체를 bash 5.1 `set -Eeuo pipefail` 기준으로 검토 | 확정 결함 3건, 위험 8건, 사소한 항목 13건 → 3절과 같이 수정 |
| 형식 점검 | 전체 파일 줄바꿈(LF)·BOM 확인, README 폴더 트리와 실제 파일 대조 | 이상 없음 |
| **미실행** | 이 작성 PC에 bash 실행 환경이 없어 `bash -n`/shellcheck와 클러스터 dry-run은 **실행하지 못했다** | 4절의 첫 실행 절차로 현장에서 확인 |

## 2. 출처 간 불일치와 처리

| 항목 | 출처별 내용 | 툴킷 처리 |
| --- | --- | --- |
| MaaS DSC 경로 | 3.4: `kserve.modelsAsService`(BC 실측·공식) / upstream ODH·3.5: `aigateway.modelsAsAService` | 버전 파일로 분리, 스키마 필터로 이중 확인 |
| `disableKueue` | 원 스크립트(3.0 기준) "넣지 말 것" / 3.4 문서 정식 필드 / 3.5 문서 DP | 3.4.2는 KUEUE, 3.5.1은 DEV_PREVIEW로 켬 |
| `disableTrustyBiasMetrics` | 3.5 툴킷 스크립트는 `false` 명시 / BC 3.4.2에서 MCP 메뉴 소실 재현 | 두 버전 모두 금지 필드 |
| `maasAuthPolicies` | 3.4 문서·툴킷 사용 / 3.5 문서 "사용 안 함" | 3.4.2만 적용 |
| `vLLMDeploymentOnMaaS` 표기 | 3.4 문서 표 `vLLMDeploymentOnMaas` / CRD·BC `vLLMDeploymentOnMaaS` | CRD 표기 사용 |
| Spark 키 | 3.4 릴리스노트 `kubeflowsparkoperator` / CRD `sparkoperator` | `sparkoperator` |
| Spark 3.5 | 툴킷 3.5 DSC `Removed` / 지원표 3.5 GA | FEATURE_SPARK로 Managed |
| JobSet 패키지 | 오퍼레이터 코드 `jobset-operator` / BC 미러·툴킷 `job-set` | `JOBSET_PACKAGE`(기본 job-set)로 변경 가능, 판정은 CRD로 |
| Kueue 채널 | 툴킷 3.4 `stable-v1.3`, BC 미러 1.3·1.4 / 3.5 릴리스노트 "Trainer는 1.4+ 비호환" | 두 버전 모두 1.3 |
| RHCL 버전 | 3.4 문서 1.3.x / 3.5 문서 1.4.x / 1.4.0 인증 우회, 1.4.1 rate limit 문제 | 1.4.0 차단, 1.4.1 경고 |
| MaaS DB Secret 위치 | 3.4 `redhat-ods-applications` / 3.5 infra namespace | 62가 maas-api·infra namespace로 복사 |
| CatalogSource 이름 | 문서 `cs-redhat-operator-index` / oc-mirror 버전에 따라 `-v4-xx` 접미사 | 설정값, preflight가 READY 확인 |
| OCP 최소 버전 | 설치 문서 "4.19~4.20" / 지원 구성표 4.19.9+, llm-d는 4.20+ | 지원 구성표 기준 |
| EvalHub 3.5 | 지원표 TP / 릴리스노트 GA | 기능 매트릭스에 둘 다 표기 |
| Model Registry DB | 지원 구성표 MySQL 8 권장 / BC PostgreSQL 16 검증 | `MR_DB_TYPE` 선택 |

## 3. 정적 리뷰 수정 내역

| 등급 | 문제 | 수정 |
| --- | --- | --- |
| 확정 | Gateway가 없을 때 `sync_gateway_access_label`이 `set -e`로 종료 → 기본 dry-run의 `all`이 llmd에서 멈춤 | 조회 실패를 허용(실패 시 빈 값) |
| 확정 | 같은 실행에서 백업 파일이 덮여 롤백 기준이 중간 상태가 됨 | 최초 백업 유지 |
| 확정 | `put_secret` 실패 시 비밀번호가 담긴 임시 파일이 남음 | subshell + EXIT trap으로 항상 삭제, 공통 함수로 이동 |
| 위험 | 버전 함수가 미정의 변수로 실패해도 부분 목록으로 DSC를 patch | `collect`로 실패 시 중단 + env.example 기본값 자동 보충 |
| 위험 | `DRY_RUN=TRUE`/`yes`가 실제 적용으로 처리 | 정확히 `false`일 때만 실제 적용 |
| 위험 | TLS·DB Secret dry-run 실패 시 경고 대신 종료 | 경고로 변경 |
| 위험 | CA 중복 판정이 PEM 헤더·CRLF에 취약 | `openssl x509`로 정규화 |
| 위험 | Authorino Service·Deployment 생성 전에 TLS 설정 | 생성 대기 후 진행 |
| 위험 | InstallPlan 대기 시간 초과가 스크립트 전체 중단, 승인 대기 중 CRD를 600초 대기 | 경고로 변경, 승인 대기면 CRD 대기 생략 |
| 위험 | DB 비밀번호 URL 미인코딩 | `@uri` 인코딩(환경변수로 전달) |
| 위험 | `LLMD_TLS_*`, `LLMD_STANDALONE_GATEWAY` 등 문서에 없는 변수 | env.example에 추가 |
| 사소 | `confirm` 미초기화 변수, 빈 값 `to_json`, patch 형식 검사, envsubst 요구 위치, verify의 중단·중복 출력, 렌더 기록 덮어쓰기, MaaS Secret 복사본 갱신, 캐시 nodeSelector 형식, namespace 공백, null `has()`, Dashboard 주소 조회, 미사용 변수, `grep -q` SIGPIPE | 모두 수정 |

## 4. 현장 첫 실행 전 확인 (필수)

```bash
bash -n scripts/*.sh scripts/lib/common.sh config/*.sh config/versions/*.sh && echo SYNTAX_OK
command -v shellcheck && shellcheck -x scripts/*.sh scripts/lib/common.sh
./scripts/rhoai-enable.sh preflight
mkdir -p evidence
./scripts/rhoai-enable.sh all 2>&1 | tee evidence/first-dryrun.log    # DRY_RUN=true
grep -E 'WARN|FAIL|스키마에 없는' evidence/first-dryrun.log
```

dry-run 로그의 "스키마에 없는 필드" 목록이 아래 5절 항목과 일치하는지 본다.

## 5. 남은 확인 항목 (클러스터 실측으로 확정)

| # | 항목 | 확인 명령 | 영향 |
| --- | --- | --- | --- |
| 1 | 3.5.1 MaaS DSC condition 이름 | `oc get dsc default-dsc -o jsonpath='{.status.conditions[*].type}'` | `MAAS_READY_REGEX` |
| 2 | 3.5.1 OGXServer env 경로 | `oc explain ogxserver.spec --recursive \| grep -n env` | 72 자동 적용 여부 |
| 3 | JobSetOperator·LeaderWorkerSetOperator CR 필드 | `oc explain jobsetoperator.spec` | 매니페스트 |
| 4 | Kueue CR 위치·frameworks enum | `oc explain kueue.spec.config.integrations.frameworks` | 40 |
| 5 | HardwareProfile v1 필드(identifiers·scheduling) | `oc explain hardwareprofile.spec --recursive --api-version=infrastructure.opendatahub.io/v1` | 41 |
| 6 | ModelRegistry 인증 프록시·DB 필드 | `oc explain modelregistry.spec --recursive` | 70(스키마 자동 선택) |
| 7 | 3.5.1에서 `disableTrustyBiasMetrics` MCP 메뉴 소실 재현 여부 | `STEPWISE=true`로 확인 | 금지 목록 유지 여부 |
| 8 | 폐쇄망 Service Mesh 3 구독의 source 카탈로그 | `oc get sub -n openshift-operators servicemeshoperator3 -o yaml` | GatewayClass Accepted |
| 9 | 3.5.1 Dashboard 플래그 실제 동작(TP/DP 메뉴 노출) | 관리자·일반 사용자 화면 | 기능 매트릭스 갱신 |
| 10 | RHBoK 설치 namespace(`openshift-kueue-operator`) | `oc get packagemanifest kueue-operator -o yaml` | 10 |

확정 결과는 `config/versions/<버전>.sh` 주석과 `docs/00-feature-matrix.md` 7절에 반영한다.
