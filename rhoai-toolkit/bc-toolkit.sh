#!/usr/bin/env bash
# BC카드 폐쇄망 RHOAI 툴킷 진입점 (hyogrin/RHOAI-Toolkit의 rhoai-toolkit.sh 명령 방식을 폐쇄망용으로 단순화)
#
#   ./bc-toolkit.sh                     메뉴
#   ./bc-toolkit.sh init                config/env.sh 생성(BC 값) + 문법 검사
#   ./bc-toolkit.sh images              스크립트 실행용 이미지가 내부 레지스트리에 있는지 확인(켜진 기능만)
#   ./bc-toolkit.sh install             전체 기능 구성(기본 dry-run). 실제 적용: DRY_RUN=false ./bc-toolkit.sh install
#   ./bc-toolkit.sh step <단계...>       일부 단계만(예: step preflight dsc dashboard)
#   ./bc-toolkit.sh verify              구성 결과 확인(조회 전용)
#   ./bc-toolkit.sh workday <번호> [인자] 2026-11 작업계획서 단계 스크립트(예: workday 30 precheck)
#   ./bc-toolkit.sh check               bash -n 문법 검사
#
# 기본은 DRY_RUN=true: API 서버 dry-run으로 검증만 하고 클러스터를 바꾸지 않는다.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

say()  { printf '%s\n' "$*"; }
die()  { printf '[중단] %s\n' "$*" >&2; exit 1; }

# 기능 변수만 읽는다(oc 로그인 불필요)
load_features() {
  [[ -f config/env.sh ]] || die "config/env.sh가 없습니다. ./bc-toolkit.sh init 을 먼저 실행하세요."
  set +u
  # shellcheck source=/dev/null
  source config/env.sh
  # shellcheck source=/dev/null
  if [[ -f config/env.example.sh ]]; then source config/env.example.sh; fi
  set -u
}

cmd_check() {
  local f n=0 bad=0
  while IFS= read -r f; do
    n=$((n + 1))
    bash -n "$f" || { say "  문법 오류: $f"; bad=$((bad + 1)); }
  done < <(find . -name '*.sh' -not -path './evidence/*' -not -path './out/*' | sort)
  say "문법 검사: ${n}개 중 오류 ${bad}개"
  command -v shellcheck >/dev/null && { shellcheck -x -S warning bc-toolkit.sh scripts/*.sh workday/*.sh || true; }
  ((bad == 0))
}

cmd_init() {
  if [[ -f config/env.sh ]]; then say "config/env.sh 있음 — 유지"; else
    cp config/env.bc.sh config/env.sh && chmod 600 config/env.sh && say "config/env.sh 생성(BC 값). 필요한 값을 확인하세요."
  fi
  local t
  for t in oc jq envsubst curl openssl; do command -v "$t" >/dev/null || say "  [WARN] 도구 없음: $t"; done
  find . -name '*.sh' -not -path './evidence/*' -exec chmod +x {} +
  cmd_check
}

# 켜진 기능의 스크립트 실행용 이미지만 골라 workday/05-image-gap-check.sh(ONLY_EXTRA)로 대조한다.
#   반환: 0 모두 있음 / 1 미반입 있음 / 2 확인 자체 실패(oc 로그인 등)
cmd_images() {
  load_features
  local list out img vars v on rc=0
  list=$(mktemp)
  while read -r img vars _; do
    [[ -z "$img" || "$img" == \#* ]] && continue
    if [[ "$img" == \$* ]]; then v=${img#\$}; img=${!v:-}; [[ -n "$img" ]] || continue; fi
    on=true
    if [[ "$vars" != "-" ]]; then
      for v in ${vars//,/ }; do [[ "${!v:-false}" == "true" ]] || on=false; done
    fi
    [[ "$on" == true ]] && echo "$img" >>"$list"
  done < mirror/runtime-images.txt
  say "확인 대상 $(wc -l <"$list")개 (mirror/runtime-images.txt 중 켜진 기능):"
  sed 's/^/    /' "$list"
  if [[ ! -s "$list" ]]; then rm -f "$list"; say "[OK] 확인할 이미지 없음"; return 0; fi
  mkdir -p "$ROOT/out"
  out="$ROOT/out/image-gap-runtime-$(date +%Y%m%d-%H%M%S)-$$"
  ONLY_EXTRA=true EXTRA_FILE="$list" GAP_DIR="$out" bash workday/05-image-gap-check.sh || rc=$?
  rm -f "$list"
  if [[ ! -f "$out/result.tsv" ]]; then say "[실패] 이미지 확인을 끝내지 못했습니다(exit $rc). oc 로그인·레지스트리 인증을 확인하세요."; return 2; fi
  if grep -q '^ERROR' "$out/result.tsv"; then
    say "[실패] 레지스트리 조회 오류(인증·인증서·연결)로 반입 여부를 판단하지 못했습니다:"
    awk -F'\t' '$1 == "ERROR" { print "    " $2 " → " $3 }' "$out/result.tsv"
    return 2
  fi
  if [[ -s "$out/images-missing.txt" ]]; then
    say "[미반입] 아래 이미지를 02_이미지반입/imageset-02 [S]로 반입하거나 해당 기능 변수를 false로 바꾸세요:"
    sed 's/^/    /' "$out/images-missing.txt"
    return 1
  fi
  say "[OK] 스크립트 실행용 이미지 모두 있음"
}

cmd_install() {
  load_features
  say "== 1/2 스크립트 실행용 이미지 확인"
  local rc=0
  cmd_images || rc=$?
  if ((rc != 0)); then
    [[ "${SKIP_IMAGE_CHECK:-false}" == "true" ]] || die "스크립트 실행용 이미지 확인 결과 $([[ $rc == 1 ]] && echo '미반입 있음' || echo '확인 실패')로 중단합니다(무시하려면 SKIP_IMAGE_CHECK=true)."
    say "[WARN] SKIP_IMAGE_CHECK=true: 이미지 확인 결과를 무시하고 진행합니다."
  fi
  say "== 2/2 기능 구성 (DRY_RUN=${DRY_RUN:-true})"
  bash scripts/rhoai-enable.sh all
  [[ "${DRY_RUN:-true}" == "false" ]] || say "dry-run 완료. 결과를 확인한 뒤 DRY_RUN=false ./bc-toolkit.sh install 로 적용합니다."
}

cmd_workday() {
  local n=${1:-}; shift || true
  [[ -n "$n" ]] || { ls workday/*.sh | sed 's#workday/#  #'; return 0; }
  local f
  f=$(ls workday/"${n}"-*.sh 2>/dev/null | head -1)
  [[ -n "$f" ]] || die "workday/${n}-*.sh 없음"
  bash "$f" "$@"
}

menu() {
  local c
  while true; do
    say ""
    say "BC RHOAI 폐쇄망 툴킷 (DRY_RUN=${DRY_RUN:-true})"
    say "  1) init     설정 파일 생성·문법 검사"
    say "  2) images   스크립트 실행용 이미지 확인"
    say "  3) install  전체 기능 구성"
    say "  4) verify   구성 결과 확인"
    say "  5) workday  작업계획서 단계 스크립트 목록"
    say "  0) 종료"
    read -r -p "선택: " c
    case "$c" in
      1) cmd_init || true ;; 2) cmd_images || true ;; 3) cmd_install || true ;;
      4) bash scripts/rhoai-enable.sh verify || true ;; 5) cmd_workday ;; 0) exit 0 ;;
      *) say "잘못된 선택" ;;
    esac
  done
}

case "${1:-menu}" in
  menu) menu ;;
  init) cmd_init ;;
  check) cmd_check ;;
  images) cmd_images ;;
  install) cmd_install ;;
  step) shift; (($# > 0)) || die "단계를 지정하세요: ./bc-toolkit.sh step preflight dsc"; bash scripts/rhoai-enable.sh "$@" ;;
  verify) bash scripts/rhoai-enable.sh verify ;;
  workday) shift; cmd_workday "$@" ;;
  var) shift; load_features 2>/dev/null; v=${1:?변수 이름}; printf '%s\n' "${!v:-}" ;;   # 복구 명령용: B=$(bash bc-toolkit.sh var BACKUP_DIR)
  -h|--help|help) sed -n '2,15p' "$0" ;;
  *) die "알 수 없는 명령: $1 (./bc-toolkit.sh help)" ;;
esac
