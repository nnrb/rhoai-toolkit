# bc-rhoai-toolkit

BC카드 폐쇄망 OpenShift(4.20)·RHOAI 3.4.2(이후 3.5.1) 작업계획서용 스크립트 저장소입니다. 인터넷 구간에서 git bundle로 만들어 반입하고, 폐쇄망 bastion의 `/data/ocp/bc-rhoai-toolkit`에서 작업계획서 단계의 명령을 실행합니다. 작업계획서의 S 시트에도 같은 파일이 들어 있습니다(git 반입본이 없을 때 시트 블록을 붙여넣어 생성).

[hyogrin/RHOAI-Toolkit](https://github.com/hyogrin/RHOAI-Toolkit)(데모에 쓴 인터넷 환경용 툴킷)을 참조해 폐쇄망용으로 다시 작성했습니다. 미러 카탈로그만 쓰고, 인터넷이 필요한 단계(GitHub·HuggingFace·PyPI)와 기존 설정을 덮어쓰는 동작(router 기본 인증서 교체, cluster-monitoring-config·DSC 전체 apply)은 뺐습니다.

## 1. 작업계획서와 스크립트

| 작업계획서(01_작업계획서) | 실행 방식 | 사용 스크립트 |
| --- | --- | --- |
| 01 OCP z-stream 업그레이드 | 수동 명령(스크립트 없음) | — |
| 02 HTTP/2 구성 | 스크립트 | `workday/30-http2.sh` (backup·precheck·enable·cert·verify·evidence·rollback-*) |
| 03 RHOAI 3.4.2 모든 기능 활성화 | 스크립트 | `scripts/01-backup.sh rhoai342`, `00`, `workday/10-mirror-apply.sh`, `20·21·22·23·41·30·64·65·70·71·90`, `99-rollback.sh` |
| 04 MaaS·llm-d·OTel 구성 | 스크립트 | `01-backup.sh maas`, `02-certs.sh`, `12-rhcl-deps.sh`(authorino 구독 전환), `10·11`, `50·60·61·62·63`, `75-maas-test.sh`, `76-llmd-test.sh`, `80·81·82·83`(OTel), `90` |
| 05 RHOAI 3.5.1 업그레이드 후 기능 활성화 | 스크립트 | `01-backup.sh rhoai351`, `workday/10-mirror-apply.sh`(MIRROR_PROFILE=rhoai351), `05-rhoai-upgrade.sh`, `11`, `20·21·23·41·30·62·63·64·65·71·90` |

공통 규칙
- 설정 파일은 `config/env.sh` 하나입니다(`bash bc-toolkit.sh init`이 `config/env.bc.sh`를 복사). `<...>` 값을 현장 값으로 바꿉니다.
- 사전 백업 경로는 `BACKUP_DIR`(기본 `/data/backup/202611`)이고, 작업계획서별 하위 디렉터리(`http2`, `rhoai342`, `maas`, `rhoai351`)에 저장합니다. 이미 있는 파일은 덮어쓰지 않습니다(다시 받으려면 `FORCE_BACKUP=true`).
- 변경 스크립트는 기본 `DRY_RUN=true`(API 서버 dry-run)입니다. 작업계획서는 dry-run 결과를 본 뒤 `DRY_RUN=false`로 적용합니다. 적용 전 확인 질문이 나옵니다.
- 복구 명령에서 설정 값이 필요하면 `bash bc-toolkit.sh var BACKUP_DIR`처럼 읽습니다.

## 2. 반입 (git bundle)

```bash
# [인터넷 구간, git 있는 Linux]
./tools/make-bundle.sh /data/mirror/toolkit        # bc-rhoai-toolkit-<날짜>.bundle + SHA256SUMS (참조 원본도: WITH_UPSTREAM=true)
# [폐쇄망 bastion]
cd /data/mirror/toolkit && sha256sum -c SHA256SUMS
git clone bc-rhoai-toolkit-<날짜>.bundle /data/ocp/bc-rhoai-toolkit
cd /data/ocp/bc-rhoai-toolkit && bash bc-toolkit.sh init
```

`make-bundle.sh`는 `config/env.sh`, 인증서·키, `evidence/`·`out/`이 추적 대상이거나 개인키가 든 파일이 있으면 중단하고, `*.sh`를 실행 권한으로 기록합니다.

## 3. 스크립트 실행용 이미지

스크립트가 직접 띄우는 Pod의 이미지입니다(`mirror/runtime-images.txt`, imageset-02 `[S]`). `bash bc-toolkit.sh images`가 켜진 기능의 이미지만 내부 레지스트리와 대조합니다.

| 이미지(설정 변수) | 스크립트 | 반입 |
| --- | --- | --- |
| `MAAS_DB_IMAGE` = rhel9/postgresql-16@sha256:cb1688… | `61-maas-db.sh` | 2026-08 반입분 |
| `REDIS_IMAGE` = rhel9/redis-7:latest | `63-maas-fixes.sh` | imageset-02 [S2] |
| `MCP_SERVER_IMAGE` = redhat-ai-services/kubernetes-mcp-server:latest | `71-mcp-servers.sh` | imageset-02 [S3] |
| `OTEL_PYTHON_IMAGE` = autoinstrumentation-python:0.54b1 | `81-otel-instrumentation.sh` | imageset-02 [S1] |

## 4. 안전장치

| 장치 | 내용 |
| --- | --- |
| 기본 dry-run | 모든 apply·patch를 `--dry-run=server`로 검증만 한다 |
| 스키마 필터·부분 patch | 설치된 CRD에 없는 필드는 건너뛰고, 필요한 필드만 merge patch |
| 기존 리소스 보존 | Gateway·Limitador storage·UIPlugin·MLflow·EvalHub·TempoStack·Collector·DB Secret이 있으면 바꾸지 않음 |
| 미러 설정 | oc-mirror 결과 IDMS/ITMS 이름에 접미사(-202611, -rhoai351)를 붙인 사본만 적용. 삭제 줄이 있으면 중단 |
| GPU 확보 | 모델 적용 중 GPU 부족이면 이전 ReplicaSet을 0으로 줄이기 전에 매번 `yes` 확인 |
| 비밀값 | DB 비밀번호·S3 자격증명·API key는 실행 중 입력, 화면·증적·git에 남기지 않음(curl 인증 헤더도 프로세스 인자에 노출하지 않음) |
| 예외 | HTTP/2 대상 Route가 이미 개별 인증서를 쓰면 원복용 Route 백업(권한 600)에 그 키가 들어 있다 |

## 5. 검증 상태

작성 PC에 bash·git·클러스터 접속이 없어 실행하지 못했습니다. 정적 검토만 거쳤습니다. 현장 첫 실행 전에 `bash bc-toolkit.sh check`(bash -n, shellcheck 있으면 함께)를 실행합니다.
