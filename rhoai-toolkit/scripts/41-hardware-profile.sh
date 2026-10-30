#!/usr/bin/env bash
# GPU Hardware Profile 생성 (Workbench·모델 배포 화면에서 선택)
#   FEATURE_KUEUE=true : Kueue LocalQueue로 스케줄링(scheduling.type=Queue)
#   FEATURE_KUEUE=false: nodeSelector/toleration으로 스케줄링(scheduling.type=Node)
#   GPU 리소스명은 노드 allocatable 실제 이름(GPU_RESOURCE_NAME)을 쓴다. MIG면 nvidia.com/mig-* 등.
source "$(dirname "$0")/lib/common.sh"
init envsubst

: "${HWP_NAME:=gpu-profile}"
: "${HWP_DISPLAY_NAME:=NVIDIA GPU}"
: "${HWP_GPU_MAX:=4}"
: "${HWP_CPU_MAX:=16}"
: "${HWP_MEM_MAX:=64Gi}"
: "${HWP_NODE_SELECTOR_KEY:=nvidia.com/gpu.present}"
: "${HWP_NODE_SELECTOR_VALUE:=true}"

has_crd hardwareprofiles.infrastructure.opendatahub.io || die "HardwareProfile CRD가 없습니다."
if oc get hardwareprofiles.infrastructure.opendatahub.io "$HWP_NAME" -n "$AI_NS" >/dev/null 2>&1; then
  ok "HardwareProfile/$HWP_NAME 이미 존재 — 변경하지 않습니다."; exit 0
fi

if is_on "$FEATURE_KUEUE"; then
  has_field hardwareprofile spec.scheduling.kueue.localQueueName infrastructure.opendatahub.io/v1 \
    || die "이 버전의 HardwareProfile 스키마에 spec.scheduling.kueue가 없습니다. oc explain 결과를 확인하세요."
  TEMPLATE=hwp-gpu-queue.yaml
else
  TEMPLATE=hwp-gpu-node.yaml
fi
export HWP_NAME HWP_DISPLAY_NAME HWP_GPU_MAX HWP_CPU_MAX HWP_MEM_MAX HWP_NODE_SELECTOR_KEY HWP_NODE_SELECTOR_VALUE \
       GPU_RESOURCE_NAME KUEUE_QUEUE_NAME AI_NS
apply_template "$TOOLKIT_ROOT/manifests/hardwareprofile/$TEMPLATE"
oc get hardwareprofiles.infrastructure.opendatahub.io -n "$AI_NS" 2>/dev/null || true
