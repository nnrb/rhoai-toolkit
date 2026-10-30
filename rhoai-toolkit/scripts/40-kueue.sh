#!/usr/bin/env bash
# Red Hat build of Kueue 구성: Kueue 인스턴스 → ResourceFlavor/ClusterQueue → 프로젝트별 LocalQueue + namespace label
#   선행: 10-operators.sh(kueue-operator), 20-dsc.sh(kueue: Unmanaged)
#   KUEUE_NAMESPACES="ns1,ns2" 로 큐를 쓸 프로젝트를 지정한다. 플랫폼 namespace 전체에 일괄 라벨을 붙이지 않는다.
source "$(dirname "$0")/lib/common.sh"
init envsubst

is_on "$FEATURE_KUEUE" || { log "FEATURE_KUEUE=false: 건너뜁니다."; exit 0; }

step "1. Kueue 인스턴스"
EXISTING_KUEUE=$(oc get kueues.kueue.openshift.io -A -o name 2>/dev/null || true)
if [[ -n "$EXISTING_KUEUE" ]]; then
  ok "Kueue 인스턴스 이미 존재($EXISTING_KUEUE) — 변경하지 않습니다."
else
  : "${KUEUE_FRAMEWORKS:=BatchJob,Pod,Deployment,StatefulSet,RayJob,RayCluster,PyTorchJob,JobSet}"
  KUEUE_FRAMEWORKS_YAML=$(jq -cn --arg f "$KUEUE_FRAMEWORKS" '$f | split(",")')
  export KUEUE_FRAMEWORKS_YAML
  apply_template "$TOOLKIT_ROOT/manifests/kueue/kueue-cluster.yaml"
  wait_for "Kueue CRD(clusterqueues) 생성" 300 has_crd clusterqueues.kueue.x-k8s.io || true
fi

step "2. ResourceFlavor / ClusterQueue ($KUEUE_QUEUE_NAME)"
if oc get clusterqueue "$KUEUE_QUEUE_NAME" >/dev/null 2>&1; then
  ok "ClusterQueue/$KUEUE_QUEUE_NAME 이미 존재 — quota는 변경하지 않습니다."
else
  export KUEUE_QUEUE_NAME GPU_RESOURCE_NAME KUEUE_CPU_QUOTA KUEUE_MEMORY_QUOTA KUEUE_GPU_QUOTA
  apply_template "$TOOLKIT_ROOT/manifests/kueue/queues.yaml"
fi

step "3. 프로젝트별 LocalQueue"
if [[ -z "${KUEUE_NAMESPACES:-}" ]]; then
  log "KUEUE_NAMESPACES가 비어 있어 LocalQueue를 만들지 않습니다. 예) KUEUE_NAMESPACES=team-a,team-b"
else
  IFS=',' read -r -a NSS <<<"$KUEUE_NAMESPACES"
  for TARGET_NS in "${NSS[@]}"; do
    TARGET_NS=${TARGET_NS// /}
    [[ -n "$TARGET_NS" ]] || continue
    export TARGET_NS
    oc get namespace "$TARGET_NS" >/dev/null 2>&1 || { warn "namespace $TARGET_NS 없음 — 건너뜀"; continue; }
    apply_template "$TOOLKIT_ROOT/manifests/kueue/localqueue.yaml" "$TARGET_NS"
    if is_dry_run; then
      log "[dry-run] oc label namespace $TARGET_NS kueue.openshift.io/managed=true"
    else
      oc label namespace "$TARGET_NS" kueue.openshift.io/managed=true --overwrite
    fi
  done
fi

step "4. 확인"
oc get resourceflavor,clusterqueue 2>/dev/null || true
oc get localqueue -A 2>/dev/null || true
log "작업에는 label kueue.x-k8s.io/queue-name=$KUEUE_QUEUE_NAME 이 필요합니다. Dashboard에서는 큐가 연결된 Hardware Profile(41-hardware-profile.sh)을 선택합니다."
