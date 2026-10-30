#!/usr/bin/env bash
# [인터넷 구간] 이 디렉터리를 git 저장소로 만들고 반입용 git bundle을 만든다.
#   사용: ./tools/make-bundle.sh [출력 디렉터리]          (기본 출력: ../bc-rhoai-toolkit-bundle)
#         WITH_UPSTREAM=true ./tools/make-bundle.sh       (참조 원본 hyogrin/RHOAI-Toolkit도 함께 bundle, 참고용)
#   결과: bc-rhoai-toolkit-<날짜>.bundle, (선택) rhoai-toolkit-upstream-<날짜>.bundle, SHA256SUMS
#   반입 후(폐쇄망): git clone bc-rhoai-toolkit-<날짜>.bundle bc-rhoai-toolkit   (자세한 절차: README.md 2절)
#   config/env.sh·인증서·evidence는 .gitignore 대상이라 bundle에 들어가지 않는다.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/../bc-rhoai-toolkit-bundle}"
DATE=$(date +%Y%m%d)
command -v git >/dev/null || { echo "git이 필요합니다." >&2; exit 1; }
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)

cd "$ROOT"
if [[ ! -d .git ]]; then
  git init -q -b main
  git config user.name  >/dev/null || git config user.name  "bc-rhoai-toolkit"
  git config user.email >/dev/null || git config user.email "bc-rhoai-toolkit@localhost"
fi
# 비밀값이 들어갈 수 있는 파일이 추적 대상이면 중단한다.
if git ls-files --others --cached --exclude-standard | grep -E '(^|/)(env\.sh|.*\.(key|pem|crt))$|^evidence/|^out/'; then
  echo "위 파일은 반입 bundle에 넣지 않습니다(.gitignore 확인)." >&2; exit 1
fi
if grep -rIlE -- '-----BEGIN [A-Z ]*PRIVATE KEY-----' --exclude-dir=.git . ; then
  echo "개인키가 포함된 파일이 있습니다. 제거 후 다시 실행하세요." >&2; exit 1
fi
bash ./bc-toolkit.sh check
# Windows에서 편집·복사한 파일은 실행 권한이 없을 수 있다 → git에 실행 권한(100755)으로 기록한다.
mapfile -t SH < <(find . -name '*.sh' -not -path './.git/*' -not -path './evidence/*' -not -path './out/*')
chmod +x "${SH[@]}"
git add -A
git update-index --chmod=+x "${SH[@]}"
git diff --cached --quiet || git commit -q -m "bc-rhoai-toolkit ${DATE}"
git tag -f "bc-${DATE}" >/dev/null
git bundle create "$OUT/bc-rhoai-toolkit-${DATE}.bundle" --all
git bundle verify "$OUT/bc-rhoai-toolkit-${DATE}.bundle"

if [[ "${WITH_UPSTREAM:-false}" == "true" ]]; then
  tmp=$(mktemp -d)
  git clone -q --mirror https://github.com/hyogrin/RHOAI-Toolkit.git "$tmp/up.git"
  git -C "$tmp/up.git" bundle create "$OUT/rhoai-toolkit-upstream-${DATE}.bundle" --all
  rm -rf "$tmp"
fi
(cd "$OUT" && sha256sum ./*.bundle > SHA256SUMS && cat SHA256SUMS)
echo "반입 대상: $OUT"
