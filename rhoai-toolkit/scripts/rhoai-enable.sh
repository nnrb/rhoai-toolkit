#!/usr/bin/env bash
# 기능 단계 실행기. 단계 이름 또는 all을 받아 순서대로 실행한다(보통 ../bc-toolkit.sh install|step 으로 부른다).
#   ./scripts/rhoai-enable.sh preflight
#   ./scripts/rhoai-enable.sh operators dsc dashboard
#   DRY_RUN=false ./scripts/rhoai-enable.sh all
# 단계 사이에 같은 EVIDENCE_DIR을 공유한다. 한 단계가 실패하면 중단한다.
set -Eeuo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

declare -A STEPS=(
  [preflight]=00-preflight.sh
  [operators]=10-operators.sh
  [dsc]=20-dsc.sh
  [observability]=21-observability.sh
  [trusted-ca]=22-trusted-ca.sh
  [observability-ui]=23-observability-ui.sh
  [dashboard]=30-dashboard.sh
  [kueue]=40-kueue.sh
  [hwprofile]=41-hardware-profile.sh
  [llmd]=50-llmd.sh
  [rhcl]=60-rhcl.sh
  [maas-db]=61-maas-db.sh
  [maas]=62-maas.sh
  [maas-fixes]=63-maas-fixes.sh
  [mlflow]=64-mlflow.sh
  [evalhub]=65-evalhub.sh
  [registry]=70-model-registry.sh
  [mcp]=71-mcp-servers.sh
  [genai-offline]=72-genai-offline.sh
  [verify]=90-verify.sh
)
# 메뉴(dashboard)는 DSC·관측·Kueue·HardwareProfile 다음에 켠다. 뒤 단계(llm-d·MaaS 등)가 실패해도 메뉴는 적용되도록 앞에 둔다.
# MaaS 메뉴는 62-maas.sh가 백엔드 구성 후 따로 켠다. maas-fixes·mlflow·evalhub·mcp는 RHOAI-Toolkit 데모 구성에서 가져온 단계다.
# genai-offline은 Playground 인스턴스를 만든 뒤 따로 실행한다(all에 포함하지 않음).
ORDER=(preflight operators dsc observability trusted-ca observability-ui kueue hwprofile dashboard llmd rhcl maas-db maas maas-fixes mlflow evalhub registry mcp verify)

usage() {
  echo "사용: $0 <단계...|all>"
  echo "단계(all 실행 순서): ${ORDER[*]}"
  echo "별도 단계: genai-offline (Playground 생성 후)"
  echo "롤백: $DIR/99-rollback.sh <dashboard|dsc|dsci> <backup-*.yaml>"
  exit 1
}
(($# > 0)) || usage

if [[ "$1" == "all" ]]; then set -- "${ORDER[@]}"; fi
for s in "$@"; do [[ -n "${STEPS[$s]:-}" ]] || { echo "알 수 없는 단계: $s"; usage; }; done

export EVIDENCE_DIR="${EVIDENCE_DIR:-$(cd "$DIR/.." && pwd)/evidence/$(date +%Y%m%d-%H%M%S)}"
for s in "$@"; do
  echo
  echo "################ [$s] ${STEPS[$s]} ################"
  bash "$DIR/${STEPS[$s]}"
done
echo
echo "완료. 기록: $EVIDENCE_DIR"
