# 공통 함수. 각 스크립트가 source 한다(단독 실행하지 않는다).
#   - 설정: 툴킷 config/env.sh (ENV_FILE로 바꿀 수 있다). WORK_ROOT·BACKUP_DIR·H2_*·MIRROR 값을 쓴다
#   - DRY_RUN=true(기본): 클러스터를 바꾸는 명령은 출력만 하거나 --dry-run=server로 검증한다. 실제 적용은 DRY_RUN=false
#   - Secret 값·개인키·API key는 출력하지 않는다.
set -Eeuo pipefail
trap 'printf "[오류] %s:%s: %s\n" "${BASH_SOURCE[0]##*/}" "$LINENO" "$BASH_COMMAND" >&2' ERR

BUNDLE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ENV_FILE=${ENV_FILE:-$(cd "$BUNDLE_DIR/.." && pwd)/config/env.sh}   # 툴킷 공통 설정(config/env.sh)
FAILS=0
WARNS=0

log()  { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }
step() { printf '\n== %s\n' "$*"; }
ok()   { printf '  [OK]   %s\n' "$*"; }
info() { printf '  [INFO] %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*"; WARNS=$((WARNS + 1)); }
fail() { printf '  [FAIL] %s\n' "$*"; FAILS=$((FAILS + 1)); }
die()  { printf '[중단] %s\n' "$*" >&2; exit 1; }

is_dry_run() { [[ "${DRY_RUN:-true}" != "false" ]]; }

# confirm <질문>: 실제 적용일 때만 yes 입력을 요구한다(ASSUME_YES=true면 생략).
confirm() {
  is_dry_run && return 0
  [[ "${ASSUME_YES:-false}" == "true" ]] && return 0
  local a=""
  read -r -p "$1 [yes 입력 시 진행] " a </dev/tty || true
  [[ "$a" == "yes" ]] || die "사용자가 취소했습니다."
}

# run <명령...>: DRY_RUN이면 출력만, 아니면 실행
run() {
  if is_dry_run; then printf '  [DRY-RUN] %s\n' "$*"; else printf '  [RUN] %s\n' "$*"; "$@"; fi
}

load_env() {
  [[ -f "$ENV_FILE" ]] || die "설정 파일이 없습니다: $ENV_FILE (bash bc-toolkit.sh init으로 만든다)"
  set +u
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  # 예전 env.sh에 없는 새 변수(RHOAI351_MIRROR_DIR 등)는 기본값으로 채운다(:= 이므로 기존 값 유지).
  local ex; ex="$(dirname "$ENV_FILE")/env.example.sh"
  # shellcheck disable=SC1090
  if [[ -f "$ex" ]]; then source "$ex"; fi
  set -u
  WORK_ROOT=${WORK_ROOT:-/data/ocp/202611}
  BACKUP_DIR=${BACKUP_DIR:-$WORK_ROOT/backup}
  [[ -n "${APPS_DOMAIN:-}" ]] || APPS_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)
  mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR" 2>/dev/null || true
}

require() {
  local t
  for t in "$@"; do command -v "$t" >/dev/null 2>&1 || die "$t 명령이 없습니다."; done
  oc whoami >/dev/null 2>&1 || die "oc 로그인이 필요합니다(cluster-admin)."
}

# filled <변수>: 값이 있고 "<...>" 자리표시자가 아니면 참
filled() { local v="${!1:-}"; [[ -n "$v" && "${v:0:1}" != "<" ]]; }
need_var() { local v; for v in "$@"; do filled "$v" || die "env.sh의 $v 값을 채우세요."; done; }

# 증적 디렉터리: ${WORK_ROOT}/evidence/scripts-YYYYMMDD
evidence_dir() {
  EVID="${WORK_ROOT}/evidence/scripts-$(date +%Y%m%d)"
  mkdir -p "$EVID" && chmod 700 "$EVID" 2>/dev/null || true
}

# deletions_in_diff <oc diff 출력 파일>: 기존 매핑 삭제 줄 수('-'로 시작, '---'·generation·resourceVersion·last-applied 줄 제외)
deletions_in_diff() {
  local n
  n=$(grep -E '^-[^-]' "$1" 2>/dev/null | grep -vcE '^-[[:space:]]+(generation|resourceVersion):|last-applied-configuration|^-[[:space:]]+\{' || true)
  echo "${n:-0}"
}

# mirror_copy <cluster-resources 디렉터리> <출력 디렉터리>
#   oc-mirror v2 결과의 IDMS/ITMS 파일을 복사하면서 객체 이름에 MIRROR_SUFFIX(기본 -202611)를 붙인다.
#   BC 클러스터에는 oc-mirror v2가 만든 idms-generic-0·itms-generic-0·idms-release-0이 이미 있어,
#   원본 이름 그대로 적용하면 기존 매핑을 덮어써 지운다. 새 이름으로 적용하면 추가만 된다(같은 매핑이 겹쳐도 무해).
mirror_copy() {
  local src=$1 out=$2 f
  mkdir -p "$out"
  for f in "$src"/idms-*.yaml "$src"/itms-*.yaml; do
    [[ -f "$f" ]] || continue
    sed -E "s/^(  name: i[dt]ms-[a-z]+-[0-9]+)\$/\\1${MIRROR_SUFFIX:--202611}/" "$f" > "$out/$(basename "$f")"
  done
}

summary() {
  printf '\n결과: FAIL=%d WARN=%d\n' "$FAILS" "$WARNS"
  trap - ERR
  [[ $FAILS -eq 0 ]]
}

GPU_SEL='nvidia.com/gpu.present=true'
