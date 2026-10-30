#!/usr/bin/env bash
# 공통 함수 라이브러리. scripts/*.sh 가 source 한다.
#
# 원칙
#   1. 기본은 DRY_RUN=true. 모든 apply/patch를 --dry-run=server로 API 서버에서 검증만 한다.
#   2. 변경 전 대상 리소스를 EVIDENCE_DIR에 백업한다.
#   3. 전체 CR을 apply하지 않고 merge patch로 필요한 필드만 바꾼다.
#   4. 설치된 CRD 스키마(oc explain)에 없는 필드는 건너뛴다. 버전 차이로 인한 오적용을 막는다.

set -Eeuo pipefail

TOOLKIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export TOOLKIT_ROOT

# ---------------------------------------------------------------- 출력
if [[ -t 1 ]]; then
  C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[34m'; C_0=$'\e[0m'
else
  C_R=''; C_G=''; C_Y=''; C_B=''; C_0=''
fi
log()  { printf '%s[INFO]%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%s[FAIL]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
step() { printf '\n%s==== %s ====%s\n' "$C_B" "$*" "$C_0"; }

trap 'warn "명령 실패 (line ${LINENO}): ${BASH_COMMAND}"' ERR

# 안전 쪽으로 판정: 정확히 "false"일 때만 실제 적용한다(TRUE·yes·1 등은 dry-run).
is_dry_run() { local v="${DRY_RUN:-true}"; [[ "${v,,}" != "false" ]]; }
is_on()      { [[ "${1:-false}" == "true" ]]; }

# 운영 변경 전 확인. ASSUME_YES=true면 묻지 않는다.
confirm() {
  is_dry_run && return 0
  is_on "${ASSUME_YES:-false}" && return 0
  local ans=""
  read -r -p "$1 [y/N] " ans </dev/tty || true
  [[ "$ans" =~ ^[Yy]$ ]] || die "사용자가 중단했습니다."
}

# ---------------------------------------------------------------- 설정
load_config() {
  local cfg="${TOOLKIT_CONFIG:-$TOOLKIT_ROOT/config/env.sh}"
  [[ -f "$cfg" ]] || die "설정 파일이 없습니다: $cfg (cp config/env.example.sh config/env.sh 후 값을 채우세요)"
  # shellcheck source=/dev/null
  source "$cfg"
  [[ -n "${RHOAI_VERSION:-}" ]] || die "config/env.sh에 RHOAI_VERSION(3.4.2 또는 3.5.1)을 지정하세요."
  # 예전 env.sh에 없는 새 변수의 기본값을 채운다(:= 이므로 기존 값은 바꾸지 않는다).
  # shellcheck source=/dev/null
  source "$TOOLKIT_ROOT/config/env.example.sh"
  local vf="$TOOLKIT_ROOT/config/versions/${RHOAI_VERSION}.sh"
  [[ -f "$vf" ]] || die "지원하지 않는 버전입니다: ${RHOAI_VERSION} (config/versions/ 참고)"
  # shellcheck source=/dev/null
  source "$vf"

  if is_dry_run; then DRY_RUN=true; else DRY_RUN=false; fi
  OPERATOR_NS="${OPERATOR_NS:-redhat-ods-operator}"
  AI_NS="${AI_NS:-redhat-ods-applications}"
  DSC_NAME="${DSC_NAME:-default-dsc}"
  DSCI_NAME="${DSCI_NAME:-default-dsci}"
  DASH_NAME="${DASH_NAME:-odh-dashboard-config}"
  if [[ -z "${EVIDENCE_DIR:-}" ]]; then
    EVIDENCE_DIR="$TOOLKIT_ROOT/evidence/$(date +%Y%m%d-%H%M%S)"
  fi
  mkdir -p "$EVIDENCE_DIR"
  chmod 700 "$EVIDENCE_DIR"
  if [[ -z "${APPS_DOMAIN:-}" ]]; then APPS_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true); fi
  if [[ -z "${MAAS_HOSTNAME:-}" || "$MAAS_HOSTNAME" == "maas." ]]; then MAAS_HOSTNAME="maas.$APPS_DOMAIN"; fi
  export DRY_RUN OPERATOR_NS AI_NS DSC_NAME DSCI_NAME DASH_NAME EVIDENCE_DIR RHOAI_VERSION APPS_DOMAIN MAAS_HOSTNAME

  if is_dry_run; then
    log "DRY_RUN=true: 변경하지 않고 API 서버 검증만 합니다. 실제 적용은 DRY_RUN=false"
  else
    warn "DRY_RUN=false: 클러스터를 변경합니다. 백업 위치: $EVIDENCE_DIR"
  fi
}

require_tools() {
  local t
  for t in oc jq "$@"; do
    command -v "$t" >/dev/null 2>&1 || die "필요한 도구가 없습니다: $t"
  done
}

require_admin() {
  oc whoami >/dev/null 2>&1 || die "oc 로그인이 필요합니다."
  oc auth can-i '*' '*' --all-namespaces >/dev/null 2>&1 || die "cluster-admin 권한이 필요합니다."
}

# 모든 스크립트의 공통 시작 절차
init() {
  require_tools "$@"
  load_config
  require_admin
}

# ---------------------------------------------------------------- 버전
detect_rhoai_version() {
  oc get csv -n "$OPERATOR_NS" -o json 2>/dev/null \
    | jq -r '[.items[] | select(.metadata.name | startswith("rhods-operator.")) | .spec.version][0] // empty'
}

# 설치 버전과 설정 버전의 minor가 다르면 중단한다. z-stream 차이는 경고만 한다.
check_version_match() {
  local actual
  actual="$(detect_rhoai_version || true)"
  [[ -n "$actual" ]] || die "rhods-operator CSV를 찾지 못했습니다(namespace: $OPERATOR_NS)."
  if [[ "$actual" == "$RHOAI_VERSION" ]]; then
    ok "RHOAI 버전 일치: $actual"
  elif [[ "${actual%.*}" == "${RHOAI_VERSION%.*}" ]]; then
    warn "z-stream 차이: 설치 $actual / 설정 $RHOAI_VERSION. minor가 같으므로 계속합니다."
  else
    die "버전 불일치: 설치 $actual / 설정 $RHOAI_VERSION. config/env.sh의 RHOAI_VERSION을 확인하세요."
  fi
}

# ---------------------------------------------------------------- 스키마
# has_field <resource> <path> [api-version]
#   예) has_field odhdashboardconfig spec.dashboardConfig.genAiStudio
has_field() {
  local res=$1 path=$2 api=${3:-}
  oc explain "${res}.${path}" ${api:+--api-version="$api"} >/dev/null 2>&1
}

has_crd() { oc get crd "$1" >/dev/null 2>&1; }

# 값 문자열을 JSON으로 바꾼다. true/false/숫자/{}/[]/"..."는 그대로, 나머지는 문자열.
to_json() {
  [[ -n "$1" ]] || { printf '""'; return 0; }
  if jq . >/dev/null 2>&1 <<<"$1"; then printf '%s' "$1"; else jq -cn --arg s "$1" '$s'; fi
}

# 버전 함수 출력을 배열로 받는다. 함수가 실패(예: 미정의 변수)하면 부분 목록으로 진행하지 않고 중단한다.
#   collect <배열이름> <함수>
collect() {
  local __out
  __out=$("$2") || die "$2 실행 실패 — config/env.sh 변수를 확인하세요."
  if [[ -n "$__out" ]]; then mapfile -t "$1" <<<"$__out"; else eval "$1=()"; fi
}

# build_patch <prefix> <item...>     item = "a.b.c=값"
#   예) build_patch spec.components "kserve.managementState=Managed"
#       → {"spec":{"components":{"kserve":{"managementState":"Managed"}}}}
build_patch() {
  local prefix=$1; shift
  local out='{}' item path val
  for item in "$@"; do
    path=${item%%=*}
    val=$(to_json "${item#*=}")
    out=$(jq -c --arg p "${prefix}.${path}" --argjson v "$val" 'setpath($p | split("."); $v)' <<<"$out")
  done
  printf '%s\n' "$out"
}

# filter_items <resource> <api-version|""> <prefix> <item...>
#   스키마에 있는 항목만 stdout으로 내보내고, 없는 항목은 경고한다.
filter_items() {
  local res=$1 api=$2 prefix=$3; shift 3
  local item path
  for item in "$@"; do
    path=${item%%=*}
    if has_field "$res" "${prefix}.${path}" "$api"; then
      printf '%s\n' "$item"
    else
      warn "스키마에 없는 필드라 건너뜁니다: ${res}.${prefix}.${path}"
    fi
  done
}

# ---------------------------------------------------------------- 백업
# backup <kind> <name> [namespace]
#   같은 EVIDENCE_DIR에 이미 백업이 있으면 유지한다(최초 상태를 보존해 롤백 기준으로 쓴다).
backup() {
  local kind=$1 name=$2 ns=${3:-}
  local f="$EVIDENCE_DIR/backup-${kind//\//_}-${name}${ns:+-$ns}.yaml"
  if [[ -s "$f" ]]; then log "기존 백업 유지(최초 상태): $f"; return 0; fi
  if oc get "$kind" "$name" ${ns:+-n "$ns"} -o yaml >"$f" 2>/dev/null; then
    log "백업: $f"
  else
    rm -f "$f"
  fi
}

# ---------------------------------------------------------------- 적용
# k_apply <file>   (DRY_RUN이면 server dry-run. 선행 리소스가 없어 dry-run이 실패하면 경고만 한다)
k_apply() {
  local f=$1
  if is_dry_run; then
    if oc apply --dry-run=server -f "$f" >/dev/null 2>"$EVIDENCE_DIR/.dryrun.err"; then
      ok "[dry-run] apply 검증 통과: $(basename "$f")"
    else
      warn "[dry-run] apply 검증 실패: $(basename "$f") — $(tail -1 "$EVIDENCE_DIR/.dryrun.err")"
      warn "          (namespace·CRD를 앞 단계에서 만들 예정이면 정상일 수 있습니다)"
    fi
  else
    oc apply -f "$f"
  fi
}

# k_patch <kind> <name> <namespace|""> <merge|json> <patch-json>
k_patch() {
  local kind=$1 name=$2 ns=$3 type=$4 patch=$5
  jq -e 'type == "object" or type == "array"' >/dev/null 2>&1 <<<"$patch" || die "patch JSON 형식 오류: '$patch'"
  log "patch ${kind}/${name}: $(jq -c . <<<"$patch")"
  if is_dry_run; then
    if oc patch "$kind" "$name" ${ns:+-n "$ns"} --type="$type" -p "$patch" --dry-run=server -o json \
         >/dev/null 2>"$EVIDENCE_DIR/.dryrun.err"; then
      ok "[dry-run] patch 검증 통과"
    else
      warn "[dry-run] patch 검증 실패 — $(tail -1 "$EVIDENCE_DIR/.dryrun.err")"
    fi
  else
    oc patch "$kind" "$name" ${ns:+-n "$ns"} --type="$type" -p "$patch"
  fi
}

# render <template>
#   템플릿의 ${VAR}만 치환한다(다른 $ 문자는 그대로). 값이 없는 변수가 있으면 중단한다.
render() {
  local f=$1 vars v name
  local -a missing=()
  vars=$(grep -o '\${[A-Z_][A-Z0-9_]*}' "$f" | sort -u || true)
  for v in $vars; do
    name=${v#\$\{}; name=${name%\}}
    if [[ -z "${!name:-}" ]]; then missing+=("$name"); else export "${name?}"; fi
  done
  ((${#missing[@]} == 0)) || die "$(basename "$f"): 값이 없는 변수 ${missing[*]} (config/env.sh 확인)"
  if [[ -n "$vars" ]]; then
    envsubst "$(tr '\n' ' ' <<<"$vars")" <"$f"
  else
    cat "$f"
  fi
}

# apply_template <template> [구분자]   렌더링 결과를 EVIDENCE_DIR에 남기고 적용한다(템플릿에는 비밀값을 넣지 않는다).
#   같은 템플릿을 여러 번 쓰면 구분자(namespace·이름)를 주어 기록이 덮이지 않게 한다.
apply_template() {
  local src=$1 tag=${2:-} out
  out="$EVIDENCE_DIR/rendered-${tag:+$tag-}$(basename "$src")"
  render "$src" >"$out"
  k_apply "$out"
}

# ---------------------------------------------------------------- 대기
# wait_for <설명> <timeout초> <명령...>
wait_for() {
  local desc=$1 timeout=$2; shift 2
  if is_dry_run; then log "[dry-run] 대기 생략: $desc"; return 0; fi
  local start=$SECONDS
  until "$@" >/dev/null 2>&1; do
    if (( SECONDS - start > timeout )); then warn "시간 초과(${timeout}s): $desc"; return 1; fi
    sleep 10
  done
  ok "$desc"
}

csv_succeeded() { # csv_succeeded <namespace> <csv 이름 접두어>
  oc get csv -n "$1" -o json 2>/dev/null | jq -e --arg p "$2" \
    '[.items[] | select(.metadata.name | startswith($p)) | select(.status.phase == "Succeeded")] | length > 0' >/dev/null
}

dsc_condition() { # dsc_condition <type> → status 문자열
  oc get datasciencecluster "$DSC_NAME" -o json 2>/dev/null \
    | jq -r --arg t "$1" '[.status.conditions[]? | select(.type == $t) | .status][0] // empty'
}

# dsc_condition_match <정규식> → 이름이 맞는 첫 condition의 "type=status" (버전마다 condition 이름이 다를 때)
dsc_condition_match() {
  oc get datasciencecluster "$DSC_NAME" -o json 2>/dev/null \
    | jq -r --arg r "$1" '[.status.conditions[]? | select(.type | test($r; "i")) | "\(.type)=\(.status)"][0] // empty'
}

uwm_enabled() {
  local cfg
  cfg=$(oc get configmap cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null || true)
  grep -Eq '^enableUserWorkload:[[:space:]]*true' <<<"$cfg"
}

# put_secret <name> <namespace> <key=value>...
#   값을 임시 파일로 넘겨 프로세스 인자에 남지 않게 하고, 실패해도 임시 파일을 지운다(subshell + trap).
#   DRY_RUN이면 server dry-run, 실패는 경고만 한다.
put_secret() (
  set -Eeuo pipefail
  name=$1; ns=$2; shift 2
  dir=$(mktemp -d); chmod 700 "$dir"
  trap 'rm -rf "$dir"' EXIT
  args=()
  for kv in "$@"; do
    printf '%s' "${kv#*=}" >"$dir/${kv%%=*}"
    args+=(--from-file="${kv%%=*}=$dir/${kv%%=*}")
  done
  oc create secret generic "$name" -n "$ns" "${args[@]}" --dry-run=client -o yaml >"$dir/secret.yaml"
  if is_dry_run; then
    if oc apply --dry-run=server -f "$dir/secret.yaml" >/dev/null 2>"$dir/err"; then
      ok "[dry-run] Secret 검증 통과: $ns/$name"
    else
      warn "[dry-run] Secret 검증 실패: $ns/$name — $(tail -1 "$dir/err")"
    fi
  else
    oc apply -f "$dir/secret.yaml" >/dev/null
    ok "Secret 적용: $ns/$name"
  fi
)

# ---------------------------------------------------------------- Gateway
apps_domain() {
  if [[ -n "${APPS_DOMAIN:-}" ]]; then echo "$APPS_DOMAIN"; return; fi
  oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}'
}

# 사용할 GatewayClass: GATEWAY_CLASS → RHOAI가 만든 data-science-gateway-class → openshift-default
detect_gateway_class() {
  local c
  for c in ${GATEWAY_CLASS:-} data-science-gateway-class openshift-default; do
    if oc get gatewayclass "$c" >/dev/null 2>&1; then echo "$c"; return 0; fi
  done
  return 1
}

gatewayclass_accepted() {
  [[ "$(oc get gatewayclass "$1" -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null)" == "True" ]]
}

# ensure_tls_secret <secret> <namespace> <cert-file> <key-file>
#   파일이 있으면 Secret을 만들거나 갱신한다. 파일이 없으면 기존 Secret이 있어야 한다.
ensure_tls_secret() {
  local name=$1 ns=$2 crt=$3 key=$4
  # 파일 경로가 지정되었더라도 파일이 없고 Secret이 이미 있으면 기존 Secret을 쓴다.
  if [[ -n "$crt" && ! -f "$crt" ]] && oc get secret "$name" -n "$ns" >/dev/null 2>&1; then crt=""; key=""; fi
  if [[ -n "$crt" && -n "$key" && ! -f "$crt" ]] && is_dry_run; then warn "[dry-run] 인증서 파일 없음: $crt (02-certs.sh 먼저)"; return 0; fi
  if [[ -n "$crt" && -n "$key" ]]; then
    [[ -f "$crt" && -f "$key" ]] || die "인증서 파일을 찾을 수 없습니다: $crt / $key"
    local y
    y=$(oc create secret tls "$name" -n "$ns" --cert="$crt" --key="$key" --dry-run=client -o yaml)
    # 기존 Secret과 인증서가 다르면 원본을 BACKUP_DIR(700, 파일 600)에 남기고 확인 후 교체한다(증적 디렉터리에는 키를 두지 않는다).
    local cur new
    cur=$(oc get secret "$name" -n "$ns" -o jsonpath='{.data.tls\.crt}' 2>/dev/null || true)
    new=$(base64 -w0 <"$crt")
    if [[ -n "$cur" && "$cur" == "$new" ]]; then ok "TLS Secret $ns/$name 인증서 동일 — 변경하지 않음"; unset y; return 0; fi
    if [[ -n "$cur" ]] && ! is_dry_run; then
      ( umask 077; oc get secret "$name" -n "$ns" -o yaml >"$(backup_dir tls)/secret-$ns-$name.$(date +%Y%m%d-%H%M%S).yaml" )
      confirm "기존 TLS Secret $ns/$name 의 인증서를 교체합니까?(원본: $(backup_dir tls))"
    fi
    if ! is_dry_run; then
      oc apply -f - <<<"$y"
    elif oc apply --dry-run=server -f - >/dev/null 2>"$EVIDENCE_DIR/.dryrun.err" <<<"$y"; then
      ok "[dry-run] TLS Secret 검증 통과: $name"
    else
      warn "[dry-run] TLS Secret 검증 실패: $name — $(tail -1 "$EVIDENCE_DIR/.dryrun.err")"
    fi
    unset y
  elif oc get secret "$name" -n "$ns" >/dev/null 2>&1; then
    ok "TLS Secret $ns/$name 사용"
  elif is_dry_run; then
    warn "[dry-run] TLS Secret $ns/$name 이 없습니다. 실제 적용 전에 인증서 파일 경로를 지정하세요."
  else
    die "TLS Secret $ns/$name 이 없습니다. 인증서(SAN에 hostname 포함)와 키 파일 경로를 config/env.sh에 지정하세요."
  fi
}

# 기존 Gateway가 있으면 listener selector의 label 키를 읽어 GATEWAY_ACCESS_LABEL을 맞춘다.
sync_gateway_access_label() { # sync_gateway_access_label <gateway>
  local key
  key=$(oc get gateway "$1" -n openshift-ingress -o json 2>/dev/null \
    | jq -r '[.spec.listeners[]?.allowedRoutes.namespaces.selector.matchLabels // {} | keys[]][0] // empty' || true)
  if [[ -n "$key" && "$key" != "$GATEWAY_ACCESS_LABEL" ]]; then
    warn "Gateway/$1 의 namespace selector는 '$key' 입니다. 이 값으로 label을 붙입니다."
    GATEWAY_ACCESS_LABEL=$key
  fi
}

# Gateway listener가 허용하는 namespace label을 붙인다.
label_gateway_access() {
  local ns=$1
  oc get namespace "$ns" >/dev/null 2>&1 || { warn "namespace $ns 없음 — label 생략"; return 0; }
  if is_dry_run; then
    log "[dry-run] oc label namespace $ns ${GATEWAY_ACCESS_LABEL}=true"
  else
    oc label namespace "$ns" "${GATEWAY_ACCESS_LABEL}=true" --overwrite
  fi
}

label_model_namespaces() {
  local ns
  local -a nss=()
  IFS=',' read -r -a nss <<<"${MODEL_NAMESPACES:-}"
  for ns in "${nss[@]}"; do
    ns=${ns// /}
    if [[ -n "$ns" ]]; then label_gateway_access "$ns"; fi
  done
  if [[ -z "${MODEL_NAMESPACES:-}" ]]; then
    log "MODEL_NAMESPACES가 비어 있습니다. 모델 namespace에 ${GATEWAY_ACCESS_LABEL}=true 가 있어야 HTTPRoute가 Gateway에 붙습니다."
  fi
}

# ---------------------------------------------------------------- 오퍼레이터
# 패키지를 구독한 Subscription이 있으면 "namespace/name"을 출력한다.
find_subscription() {
  oc get subscriptions.operators.coreos.com -A -o json 2>/dev/null \
    | jq -r --arg p "$1" '[.items[] | select(.spec.name == $p) | "\(.metadata.namespace)/\(.metadata.name)"][0] // empty'
}

# 미러된 CatalogSource에 패키지·채널이 있는지 확인한다.
catalog_has_channel() { # catalog_has_channel <package> <channel> <catalogsource>
  oc get packagemanifests -n openshift-marketplace -l "catalog=$3" -o json 2>/dev/null \
    | jq -e --arg p "$1" --arg c "$2" \
      '[.items[] | select(.metadata.name == $p) | .status.channels[]? | select(.name == $c)] | length > 0' >/dev/null
}

# 채널 head CSV가 지원하는 installMode로 OperatorGroup 형태를 고른다. AllNamespaces 우선.
pick_install_mode() { # pick_install_mode <package> <channel> <catalogsource> → all | own
  local modes
  modes=$(oc get packagemanifests -n openshift-marketplace -l "catalog=$3" -o json 2>/dev/null \
    | jq -r --arg p "$1" --arg c "$2" \
      '[.items[] | select(.metadata.name == $p) | .status.channels[]? | select(.name == $c)
        | .currentCSVDesc.installModes[]? | select(.supported) | .type] | join(",")')
  if [[ ",$modes," == *",AllNamespaces,"* ]]; then echo all
  elif [[ ",$modes," == *",OwnNamespace,"* ]]; then echo own
  else die "$1: 지원 installMode를 확인할 수 없습니다(${modes:-없음})."
  fi
}

# ensure_operator <package> <namespace> <channel> <auto|own|all|global> [catalogsource]
#   auto   : 카탈로그의 installModes로 결정(AllNamespaces 우선)
#   own    : 해당 namespace만 감시하는 OperatorGroup 생성
#   all    : 모든 namespace를 감시하는 OperatorGroup 생성
#   global : openshift-operators 등 기존 OperatorGroup 사용(생성하지 않음)
ensure_operator() {
  local pkg=$1 ns=$2 ch=$3 mode=$4 src=${5:-$CATALOG_SOURCE}
  local existing
  existing=$(find_subscription "$pkg")
  if [[ -n "$existing" ]]; then
    ok "$pkg: 이미 구독되어 있습니다 ($existing). 생성하지 않습니다."
    return 0
  fi
  catalog_has_channel "$pkg" "$ch" "$src" \
    || die "$pkg: CatalogSource '$src'에 채널 '$ch'이 없습니다. 미러 상태를 확인하세요 (oc get packagemanifests -l catalog=$src)."
  if [[ "$mode" == "auto" ]]; then mode=$(pick_install_mode "$pkg" "$ch" "$src"); fi

  local f="$EVIDENCE_DIR/operator-${pkg}.yaml"
  {
    if [[ "$mode" != "global" ]]; then
      printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: %s\n---\n' "$ns"
      if [[ -z "$(oc get operatorgroups -n "$ns" -o name 2>/dev/null)" ]]; then
        printf 'apiVersion: operators.coreos.com/v1\nkind: OperatorGroup\nmetadata:\n  name: %s\n  namespace: %s\nspec:' "$pkg" "$ns"
        if [[ "$mode" == "own" ]]; then
          printf '\n  targetNamespaces:\n    - %s\n---\n' "$ns"
        else
          printf ' {}\n---\n'
        fi
      fi
    fi
    cat <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${pkg}
  namespace: ${ns}
spec:
  name: ${pkg}
  channel: ${ch}
  source: ${src}
  sourceNamespace: openshift-marketplace
  installPlanApproval: ${INSTALL_PLAN_APPROVAL:-Manual}
EOF
    if [[ -n "${STARTING_CSV:-}" ]]; then printf '  startingCSV: %s\n' "$STARTING_CSV"; fi
  } >"$f"
  log "$pkg 구독 생성 (namespace=$ns, channel=$ch, source=$src)"
  k_apply "$f"
  approve_installplan "$ns" "$pkg"
}

# Manual 승인 Subscription의 InstallPlan을 확인하고 APPROVE_INSTALLPLAN=true이면 승인한다.
#   같은 namespace의 대기 중 InstallPlan은 여러 오퍼레이터의 CSV를 함께 담을 수 있으므로 목록을 출력한다.
approve_installplan() {
  local ns=$1 pkg=$2 ip=""
  is_dry_run && return 0
  [[ "${INSTALL_PLAN_APPROVAL:-Manual}" == "Manual" ]] || return 0
  local start=$SECONDS
  while [[ -z "$ip" ]] && (( SECONDS - start < 180 )); do
    ip=$(oc get subscriptions.operators.coreos.com "$pkg" -n "$ns" -o jsonpath='{.status.installPlanRef.name}' 2>/dev/null || true)
    [[ -n "$ip" ]] || sleep 5
  done
  [[ -n "$ip" ]] || { warn "$pkg: InstallPlan이 생성되지 않았습니다. CatalogSource 상태를 확인하세요."; return 0; }
  log "InstallPlan $ns/$ip 포함 CSV: $(oc get installplan "$ip" -n "$ns" -o jsonpath='{.spec.clusterServiceVersionNames}')"
  if [[ "$(oc get installplan "$ip" -n "$ns" -o jsonpath='{.spec.approved}')" == "true" ]]; then
    ok "이미 승인됨: $ip"
  elif is_on "${APPROVE_INSTALLPLAN:-false}"; then
    oc patch installplan "$ip" -n "$ns" --type=merge -p '{"spec":{"approved":true}}'
    ok "승인: $ns/$ip"
  else
    warn "승인 대기: oc patch installplan $ip -n $ns --type=merge -p '{\"spec\":{\"approved\":true}}'"
  fi
}

# 승인 대기 중이라 오퍼레이터가 설치될 수 없는 상태인지(이 경우 CRD 대기를 생략한다)
installplan_pending() { # installplan_pending <package>
  is_dry_run && return 1
  [[ "${INSTALL_PLAN_APPROVAL:-Manual}" == "Manual" ]] || return 1
  is_on "${APPROVE_INSTALLPLAN:-false}" && return 1
  local sub; sub=$(find_subscription "$1")
  [[ -n "$sub" ]] || return 1
  [[ -z "$(oc get subscriptions.operators.coreos.com -n "${sub%/*}" "${sub#*/}" -o jsonpath='{.status.installedCSV}' 2>/dev/null)" ]]
}

# bearer <key>: curl -K 용 설정을 출력한다(curl -K <(bearer "$KEY")). key가 프로세스 인자(ps)에 드러나지 않는다(printf는 내장 명령).
bearer() { printf 'header = "Authorization: Bearer %s"\n' "$1"; }

# ---------------------------------------------------------------- 사전 백업(01-backup.sh 등)
# backup_dir <대상>: ${BACKUP_DIR}/<대상> 을 만들고(권한 700) 경로를 출력한다.
backup_dir() {
  local d="${BACKUP_DIR:?config/env.sh에 BACKUP_DIR이 필요합니다}/$1"
  mkdir -p "$d" && chmod 700 "$d"
  echo "$d"
}
# save_once <파일> <명령...>: 파일이 없을 때만(또는 FORCE_BACKUP=true) 명령 출력을 저장한다(최초 상태 보존, 권한 600).
#   조회 실패(리소스·CRD 없음)는 경고 없이 빈 파일을 지운다.
save_once() {
  local f=$1; shift
  if [[ -s "$f" && "${FORCE_BACKUP:-false}" != "true" ]]; then log "유지: $f"; return 0; fi
  if "$@" >"$f" 2>/dev/null && [[ -s "$f" ]]; then chmod 600 "$f"; ok "$f"; else rm -f "$f"; log "없음(건너뜀): $(basename "$f")"; fi
}

# ---------------------------------------------------------------- GPU (검증 모델·OTel 적용 중 GPU 부족 조치)
# gpu_pending: GPU 부족으로 Pending인 Pod(namespace, Pod, 스케줄러 메시지)
gpu_pending() {
  oc get pod -A --field-selector=status.phase=Pending -o json | jq -r '.items[] | select(any(.status.conditions[]?; .type=="PodScheduled" and .status=="False" and ((.message // "") | test("nvidia.com/")))) | [.metadata.namespace, .metadata.name, (.status.conditions[] | select(.type=="PodScheduled") | .message)] | @tsv'
}
# gpu_pods: GPU를 점유한 Pod(노드, namespace, Pod, 상태, ready, GPU 리소스)
gpu_pods() {
  oc get pod -A -o json | jq -r '.items[] | select(.spec.nodeName != null and .status.phase != "Succeeded" and .status.phase != "Failed") | .status.phase as $ph | {n: .spec.nodeName, ns: .metadata.namespace, p: .metadata.name, g: ([.spec.containers[] | ((.resources.limits // {}) + (.resources.requests // {})) | to_entries[] | select(.key | startswith("nvidia.com/")) | "\(.key)=\(.value)"] | unique | join(",")), s: (if .metadata.deletionTimestamp then "Terminating" else ([.status.containerStatuses[]? | .state.waiting.reason // .state.terminated.reason // empty] | first // $ph) end), r: ([.status.containerStatuses[]? | .ready] | all)} | select(.g != "") | [.n, .ns, .p, .s, "ready=\(.r)", .g] | @tsv' | sort
}
# gpu_free_old <ns> <Pending Pod>: 같은 Deployment의 이전 revision ReplicaSet을 0으로 줄여 GPU를 확보한다(해당 모델 일시 중단).
gpu_free_old() {
  local ns=$1 pod=$2 rs d o
  rs=$(oc get pod "$pod" -n "$ns" -o jsonpath='{.metadata.ownerReferences[?(@.kind=="ReplicaSet")].name}')
  d=$(oc get rs "$rs" -n "$ns" -o jsonpath='{.metadata.ownerReferences[?(@.kind=="Deployment")].name}' 2>/dev/null || true)
  [[ -n "$d" ]] || { warn "Deployment Pod 아님: ${ns}/${pod}"; return 0; }
  [[ "$(oc get rs "$rs" -n "$ns" -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}')" == "$(oc get deploy "$d" -n "$ns" -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}')" ]] \
    || { warn "최신 revision Pod 아님: ${ns}/${pod}"; return 0; }
  while read -r o; do
    [[ -n "$o" ]] || continue
    if is_dry_run; then log "[dry-run] oc scale rs $o -n $ns --replicas=0"; continue; fi
    # 이전 Pod를 내리면 새 Pod가 뜰 때까지 해당 모델이 중단된다. ASSUME_YES와 관계없이 매번 묻는다.
    local a=""; read -r -p "${ns} rs/${o} 를 0으로 줄여 GPU를 확보합니까?(해당 모델 일시 중단) [yes 입력 시 진행] " a </dev/tty || true
    if [[ "$a" == yes ]]; then log "이전 Pod 정리: ${ns} rs/${o} replicas=0"; oc scale rs "$o" -n "$ns" --replicas=0; else warn "건너뜀: ${ns} rs/${o}"; fi
  done < <(oc get rs -n "$ns" -o json | jq -r --arg d "$d" --arg cur "$rs" '.items[] | select(any(.metadata.ownerReferences[]?; .kind=="Deployment" and .name==$d)) | select(.metadata.name != $cur and (.spec.replicas // 0) > 0) | .metadata.name')
}
# gpu_resolve <ns>: ns의 GPU 부족 Pending Pod마다 gpu_free_old 를 수행한다(60초 대기 후 판단).
gpu_resolve() {
  local ns=$1 p
  is_dry_run && return 0
  sleep 60
  while read -r p; do [[ -n "$p" ]] && gpu_free_old "$ns" "$p"; done < <(gpu_pending | awk -v ns="$ns" '$1==ns {print $2}')
  if [[ -n "$(gpu_pending)" ]]; then warn "GPU 부족 Pending이 남아 있습니다:"; gpu_pending | sed 's/^/    /'; else ok "GPU 부족 Pending 없음"; fi
}

# ---------------------------------------------------------------- OpenTelemetry
# otel_verify <isvc|llmisvc> <dry-run 결과 JSON>: 주입 annotation·OTEL env·tracing 인자가 결과에 남았는지 확인(스키마에 없는 필드는 서버가 제거)
otel_verify() {
  jq -e --arg k "$1" '(if $k=="isvc" then .spec.predictor else .spec end) as $o | (if $k=="isvc" then (.spec.predictor.model // (.spec.predictor.containers[]? | select(.name=="kserve-container"))) else (.spec.template.containers[]? | select(.name=="main")) end) as $c | (($o.annotations["instrumentation.opentelemetry.io/inject-python"] // "") != "") and any($c.env[]?; .name=="OTEL_SERVICE_NAME") and ((($c.args // []) + [($c.env[]? | select(.name=="VLLM_ADDITIONAL_ARGS") | .value)]) | join(" ") | contains("--otlp-traces-endpoint"))' "$2" >/dev/null
}
# collector_errors <deploy> <ns> <since>: Collector 전송 오류 줄 수(로그를 못 읽으면 "조회 실패")
collector_errors() {
  local l
  l=$(oc logs "deploy/$1" -n "$2" --since="$3" 2>/dev/null) || { echo "조회 실패"; return 0; }
  grep -ciE 'Exporting failed|"level":"error"|[[:space:]]error[[:space:]]' <<<"$l" || true
}
# otel_targets <isvc 목록> <llmisvc 목록>: "isvc:a llmisvc:b" 형식
otel_targets() {
  local m
  for m in $1; do printf 'isvc:%s ' "$m"; done
  for m in $2; do printf 'llmisvc:%s ' "$m"; done
}
# model_selector <isvc|llmisvc> <이름>: 모델 Pod label selector
model_selector() {
  if [[ "$1" == isvc ]]; then echo "serving.kserve.io/inferenceservice=$2"; else echo "app.kubernetes.io/name=$2,kserve.io/component=workload"; fi
}
