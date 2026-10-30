#!/usr/bin/env bash
# MCP 서버(폐쇄망) — RHOAI-Toolkit lib/manifests/mcp/kubernetes-mcp-server.yaml·workshop-setup.sh 기준
#   - Kubernetes MCP 서버(읽기 전용, --read-only)를 MCP_NS에 띄우고 Gen AI Playground MCP 목록(gen-ai-aa-mcp-servers)에 등록한다.
#   - 인터넷이 필요한 MCP(GitHub, SearXNG 웹검색, Brave)와 GitHub에서 받는 mcp-lifecycle-operator(3.4)는 넣지 않는다.
#   - 스크립트 실행용 이미지: MCP_SERVER_IMAGE(mirror/runtime-images.txt)
source "$(dirname "$0")/lib/common.sh"
init
is_on "$FEATURE_MCP_SERVERS" || { log "FEATURE_MCP_SERVERS=false: 건너뜁니다."; exit 0; }
URL="http://kubernetes-mcp-server.${MCP_NS}.svc.cluster.local:8080/mcp"

step "1. Kubernetes MCP 서버 ($MCP_NS)"
f="$EVIDENCE_DIR/kubernetes-mcp-server.yaml"
cat >"$f" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${MCP_NS}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kubernetes-mcp-server
  namespace: ${MCP_NS}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kubernetes-mcp-server-${MCP_NS}
subjects:
- kind: ServiceAccount
  name: kubernetes-mcp-server
  namespace: ${MCP_NS}
roleRef:
  kind: ClusterRole
  name: ${MCP_CLUSTER_ROLE}
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kubernetes-mcp-server
  namespace: ${MCP_NS}
  labels: {app: kubernetes-mcp-server}
spec:
  replicas: 1
  selector: {matchLabels: {app: kubernetes-mcp-server}}
  template:
    metadata: {labels: {app: kubernetes-mcp-server}}
    spec:
      serviceAccountName: kubernetes-mcp-server
      containers:
      - name: server
        image: ${MCP_SERVER_IMAGE}
        args: ["--port=8080", "--read-only"]
        ports: [{containerPort: 8080}]
        resources:
          requests: {cpu: 50m, memory: 128Mi}
          limits: {cpu: 500m, memory: 512Mi}
---
apiVersion: v1
kind: Service
metadata:
  name: kubernetes-mcp-server
  namespace: ${MCP_NS}
  labels: {app: kubernetes-mcp-server}
spec:
  selector: {app: kubernetes-mcp-server}
  ports: [{port: 8080, targetPort: 8080}]
---
# MCP 서버는 인증이 없으므로 RHOAI(${AI_NS})와 Data Science 프로젝트(opendatahub.io/dashboard=true)에서만 접근을 허용한다.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: kubernetes-mcp-server
  namespace: ${MCP_NS}
spec:
  podSelector: {matchLabels: {app: kubernetes-mcp-server}}
  policyTypes: [Ingress]
  ingress:
  - from:
    - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: ${AI_NS}}}
    - namespaceSelector: {matchLabels: {opendatahub.io/dashboard: "true"}}
    ports: [{port: 8080, protocol: TCP}]
EOF
[[ "$MCP_CLUSTER_ROLE" == view ]] || warn "MCP_CLUSTER_ROLE=$MCP_CLUSTER_ROLE (읽기 전용 view 권장)"
confirm "Kubernetes MCP 서버(${MCP_SERVER_IMAGE}, ClusterRole ${MCP_CLUSTER_ROLE})를 배포합니까?"
k_apply "$f"
wait_for "kubernetes-mcp-server Ready" 300 oc rollout status deploy/kubernetes-mcp-server -n "$MCP_NS" --timeout=10s \
  || die "MCP 서버가 Ready가 아닙니다(이미지 반입 확인: ./bc-toolkit.sh images). Playground 목록에는 등록하지 않았습니다."

step "2. Playground MCP 목록(gen-ai-aa-mcp-servers)"
CUR=$(oc get configmap gen-ai-aa-mcp-servers -n "$AI_NS" -o json 2>/dev/null || true)
if [[ -n "$CUR" ]] && jq -e '.data["Kubernetes-MCP-Server"]' >/dev/null <<<"$CUR"; then
  ok "Kubernetes-MCP-Server 이미 등록됨"
else
  [[ -n "$CUR" ]] && backup configmap gen-ai-aa-mcp-servers "$AI_NS"
  ENTRY=$(jq -cn --arg u "$URL" '{url:$u, description:"OpenShift 리소스 조회(읽기 전용, 클러스터 내부)"}')
  confirm "gen-ai-aa-mcp-servers에 Kubernetes-MCP-Server를 추가합니까?"
  if [[ -n "$CUR" ]]; then
    k_patch configmap gen-ai-aa-mcp-servers "$AI_NS" merge "$(jq -cn --arg v "$ENTRY" '{data:{"Kubernetes-MCP-Server":$v}}')"
  else
    f2="$EVIDENCE_DIR/gen-ai-aa-mcp-servers.yaml"
    oc create configmap gen-ai-aa-mcp-servers -n "$AI_NS" --from-literal=Kubernetes-MCP-Server="$ENTRY" --dry-run=client -o yaml >"$f2"
    k_apply "$f2"
  fi
fi
log "확인: Gen AI Studio Playground > MCP servers 목록, oc logs deploy/kubernetes-mcp-server -n $MCP_NS"
