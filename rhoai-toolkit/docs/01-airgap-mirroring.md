# 폐쇄망 미러링

기능 활성화 전에 RHOAI와 의존 오퍼레이터, 추가 이미지를 내부 레지스트리로 반입한다. BC 반입 파일은 `mirror/imageset-01~03-*.yaml`(02_이미지반입과 같은 파일)이고, 스크립트 실행용 이미지는 `mirror/runtime-images.txt`에 따로 적었다.

## 1. 반입 대상

| 구분 | 대상 | 반입 방법 |
| --- | --- | --- |
| RHOAI 오퍼레이터와 런타임 | `rhods-operator`(3.4.2: `stable-3.4`, 3.5.1: `stable-3.5`, min=max 버전 고정) | ImageSet `operators`. vLLM 등 런타임 이미지는 CSV relatedImages로 함께 반입된다 |
| 의존 오퍼레이터 | cert-manager, LWS, Service Mesh 3, RHCL·Authorino·Limitador·DNS, RHBoK 1.3, JobSet, COO, OpenTelemetry, Tempo, NFD, (GPU Operator) | ImageSet `operators` |
| Ray·학습·Pipeline 런타임 | Red Hat helper 저장소 목록 중 Workbench를 뺀 것(2026-10-29 요청으로 Workbench 제외) | imageset-02 [B], imageset-03 |
| 스크립트 실행용 | PostgreSQL 16(MaaS DB), Redis 7(Limitador), Kubernetes MCP 서버, OTel Python | imageset-02 [S], 확인: `./bc-toolkit.sh images` |
| 모델 | 가중치·tokenizer, modelcar(`oci://`) | 내부 S3/PVC 업로드 또는 imageset-02 [C]에 modelcar 추가 |
| 기타 | AutoML/AutoRAG의 `pipelines-components` Git 저장소, Python 패키지 | 내부 Git·PyPI 미러(RHOAIENG-59340) |

`additionalImages` 목록은 [red-hat-data-services/rhoai-disconnected-install-helper](https://github.com/red-hat-data-services/rhoai-disconnected-install-helper)의 `rhoai-<버전>-imagesetconfig.yaml`을 2026-10-22에 옮긴 것이다. 이 저장소는 GitHub Action으로 목록을 갱신하므로, 반입 직전에 다시 대조한다.

## 2. 실행 (인터넷 구간 → 폐쇄망 구간)

```bash
# 인터넷 구간: 클러스터 OCP minor에 맞춰 catalog 태그(v4.20 등)를 수정한 뒤
oc mirror -c mirror/imageset-02-rhoai-3.4.2-features.yaml file:///data/mirror-rhoai --v2

# 매체로 /data/mirror-rhoai 를 옮긴 뒤 폐쇄망 구간
oc mirror -c mirror/imageset-02-rhoai-3.4.2-features.yaml --from file:///data/mirror-rhoai \
  docker://registry.example.internal:8443 --v2

# 클러스터 리소스 적용: BC는 oc-mirror 결과 객체 이름이 기존 객체와 같아 원본을 그대로 apply하면 기존 매핑이 지워진다.
#   반드시 workday/10-mirror-apply.sh(이름에 -202611을 붙인 사본 적용)를 쓴다.
./bc-toolkit.sh workday 10
```

- 용량: RHOAI만 약 75~100GB. 의존 오퍼레이터·모델을 더하면 늘어난다.
- 채널 목록 확인(인터넷 구간): `opm render registry.redhat.io/redhat/redhat-operator-index:v4.20 | jq -r 'select(.schema=="olm.channel" and .package=="rhods-operator") | .name'`
- 기존 IDMS가 있으면 새 IDMS와 합친다(BC: `IDMS-통합-20260909/consolidated-idms.yaml`). IDMS 변경은 노드 재기동(MCP 롤아웃)을 일으킬 수 있다.

## 3. 클러스터 설정

```bash
# 온라인 기본 카탈로그 끄기
oc patch operatorhub cluster --type merge -p '{"spec":{"disableAllDefaultSources":true}}'

# 미러 카탈로그 확인 → config/env.sh 의 CATALOG_SOURCE 와 같아야 한다
oc get catalogsource -n openshift-marketplace
oc get packagemanifests -n openshift-marketplace -l catalog=cs-redhat-operator-index | grep -E 'rhods|rhcl|kueue|leader|job-set|cert-manager'
```

## 4. 폐쇄망 주의 사항

| 항목 | 내용 |
| --- | --- |
| Service Mesh 3 | OCP Gateway API가 `servicemeshoperator3`를 직접 구독한다. 패키지가 미러 카탈로그에 없으면 GatewayClass가 Accepted 되지 않는다. 수동 구독은 하지 않는다(4.21.22 미만 OCP에서 충돌) |
| RHBoK 버전 | Trainer는 RHBoK 1.4 이상과 비호환. 1.3 채널만 미러한다. OCP 4.22 카탈로그에는 1.3이 없다 |
| RHCL 버전 | 1.4.0(인증 우회), 1.4.1(rate limit 오동작)은 쓰지 않는다 |
| registry.access.redhat.com | 일부 Pipeline 이미지가 이 주소를 참조한다. IDMS에 내부 레지스트리 매핑을 추가한다(RHOAIENG-3372) |
| Hugging Face | `hf://` 모델 URI, Playground 임베딩 다운로드는 동작하지 않는다. 모델은 내부 저장소로, Playground는 `72-genai-offline.sh`로 보정한다 |
| NIM | DSC `kserve.nim.airGapped: true`(스크립트 기본). NGC 이미지와 모델 캐시는 별도 반입 |
| AMD ROCm | AMD GPU Operator·ROCm 이미지는 폐쇄망 미지원(OCPBUGS-49422) |
| Model Catalog | 메타데이터는 로컬 YAML이라 조회는 된다. 배포하려면 해당 modelcar 이미지를 반입한다 |
| 사내 CA | 내부 S3·레지스트리·DB가 사설 CA면 `22-trusted-ca.sh`로 DSCI에 등록한다 |
