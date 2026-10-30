#!/usr/bin/env bash
# HTTP/2 구성(02 HTTP2 작업계획서): 클러스터 전역 적용 + 기존 Route 인증서 변경
#   - enable: ingresses.config/cluster에 default-enable-http2=true → 모든 IngressController(router-default) rolling 재기동
#   - cert  : H2_ROUTES의 기존 Route에 인증서(H2_CERT·H2_KEY·H2_CA)를 직접 지정. 새 Route·라우터는 만들지 않는다.
#   - HTTP/2는 Route에 인증서를 직접 지정한 edge/reencrypt Route에만 협상된다. 기본 인증서(*.apps) Route는 HTTP/1.1로 남는다.
#   하위 명령
#     backup            : 사전 백업(ingresses.config, IngressController, router Pod, 대상 Route, 기존 개별 인증서 Route 목록)
#                         경로: ${BACKUP_DIR}/http2 (BACKUP_DIR은 config/env.sh 또는 명령줄). 처음 한 번만 만든다(FORCE_BACKUP=true면 다시)
#     precheck          : 사전 점검(조회 전용) annotation, router PDB, 인증서, 대상 Route
#     enable            : 전역 annotation 적용, router rolling 재기동 대기
#     cert [ns/route..] : Route 인증서 변경(인자 없으면 H2_ROUTES 전체, FIRST_ONLY=true면 첫 번째만)
#     verify            : 대상 Route h2, 기본 인증서 Route 1.1 확인(조회 전용)
#     evidence          : 증적 저장(개인키 제외)
#     rollback-cert [ns/route..] : Route spec.tls를 백업 값으로 원복
#     rollback-global   : 전역 annotation 제거(router-default rolling 재기동)
#   기본 DRY_RUN=true(서버 dry-run만). 실제 적용은 DRY_RUN=false
#   예외: 대상 Route가 이미 개별 인증서를 쓰면 backup의 Route JSON에 그 키가 들어 있다(원복에 필요). 권한 600, 작업 후 담당자 정책에 따라 삭제·격리
source "$(dirname "$0")/lib/common.sh"
load_env
require oc jq openssl curl
ANN='ingress.operator.openshift.io/default-enable-http2'
ANN_JP='{.metadata.annotations.ingress\.operator\.openshift\.io/default-enable-http2}'
PATCH_GLOBAL="$WORK_ROOT/manifests/h2-01-ingress-config-http2.patch.yaml"
H2B="$BACKUP_DIR/http2"
mkdir -p "$H2B" "$WORK_ROOT/certs" && chmod 700 "$H2B" "$WORK_ROOT/certs"
evidence_dir
AFFECTED="$H2B/h2-affected-routes.txt"
# 개인키가 든 임시 patch 파일은 어떤 경로로 끝나도(취소·오류) 지운다.
TMP_PATCH=""
trap 'rm -f "$TMP_PATCH"' EXIT
CMD=${1:-precheck}; shift || true
exec > >(tee "$EVID/30-http2-$CMD-$(date +%H%M%S).txt") 2>&1

http2_env() { oc -n openshift-ingress set env "deploy/$1" --list 2>/dev/null | awk -F= '$1=="ROUTER_DISABLE_HTTP2"{print $2}'; }
route_backup() { echo "$H2B/route-${1%%/*}-${1##*/}.before-h2.json"; }
targets() { if (($# > 0)); then printf '%s\n' "$@"; else tr ' ' '\n' <<<"$H2_ROUTES" | sed '/^$/d'; fi; }
cert_fp() { openssl x509 -noout -fingerprint -sha256 2>/dev/null || true; }
fresh() { [[ "${FORCE_BACKUP:-false}" == "true" || ! -s "$1" ]]; }
save() { local f=$1; shift; if fresh "$f"; then if "$@" > "$f"; then ok "$f"; else fail "$f 저장 실패"; fi; else info "유지: $f"; fi; }
wait_router() {
  sleep 20
  oc -n openshift-ingress rollout status deploy/router-default --timeout=15m
  local d
  for d in $(oc -n openshift-ingress get deploy -o name | grep '/router-'); do
    [[ "$(http2_env "${d#*/}")" == "$1" ]] && ok "${d#*/} ROUTER_DISABLE_HTTP2=$1" || fail "${d#*/} ROUTER_DISABLE_HTTP2=$(http2_env "${d#*/}") ($1 예상)"
  done
  oc -n openshift-ingress-operator get ingresscontroller default -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}' | grep -E '^(Available|Progressing|Degraded)=' || true
}

case "$CMD" in
  backup)
    need_var H2_ROUTES
    step "사전 백업 → $H2B (기존 파일은 유지, FORCE_BACKUP=true면 다시 받음)"
    save "$H2B/ingress-config.before-h2.yaml" oc get ingresses.config/cluster -o yaml
    save "$H2B/ingresscontroller.before-h2.yaml" oc -n openshift-ingress-operator get ingresscontroller -o yaml
    save "$H2B/router-pods.before-h2.txt" oc -n openshift-ingress get pods -o wide
    if fresh "$AFFECTED"; then
      oc get route -A -o json | jq -r '.items[] | select(.spec.tls != null and .spec.tls.termination != "passthrough" and (((.spec.tls.certificate // "") != "") or (.spec.tls.externalCertificate != null))) | [.metadata.namespace, .metadata.name, .spec.host, .spec.tls.termination] | @tsv' > "$AFFECTED"
      ok "$AFFECTED (전역 적용만으로 HTTP/2가 되는 기존 개별 인증서 Route $(wc -l < "$AFFECTED")개)"
    else
      info "유지: $AFFECTED"
    fi
    while read -r r; do
      b=$(route_backup "$r")
      if fresh "$b"; then
        if oc -n "${r%%/*}" get route "${r##*/}" -o json > "$b" 2>/dev/null; then chmod 600 "$b"; ok "$b"; else rm -f "$b"; fail "$r 없음"; fi
      else
        info "유지: $b"
      fi
    done < <(targets)
    chmod 600 "$H2B"/* 2>/dev/null || true
    ;;

  precheck)
    need_var H2_ROUTES H2_CERT H2_KEY H2_CA
    step "전역 상태"
    v=$(oc get ingresses.config/cluster -o jsonpath="$ANN_JP")
    [[ -z "$v" ]] && ok "전역 annotation 없음" || warn "전역 annotation=$v (이미 설정됨)"
    while read -r ic val; do
      [[ "$val" == "false" ]] && fail "IngressController $ic annotation=false(전역 값 무시) → 담당자 확인" || info "IngressController $ic annotation=${val:-<none>}"
    done < <(oc -n openshift-ingress-operator get ingresscontroller -o json | jq -r --arg a "$ANN" '.items[] | "\(.metadata.name) \(.metadata.annotations[$a] // "")"')
    info "router-default ROUTER_DISABLE_HTTP2=$(http2_env router-default)"
    while read -r n a; do
      [[ "${a:-0}" -ge 1 ]] && ok "PDB $n disruptionsAllowed=$a" || warn "PDB $n disruptionsAllowed=$a (router Pod 비정상 가능성 → 아래 Ready 확인)"
    done < <(oc get pdb -n openshift-ingress -o custom-columns=NAME:.metadata.name,ALLOWED:.status.disruptionsAllowed --no-headers)
    rr=$(oc -n openshift-ingress get deploy router-default -o jsonpath='{.status.readyReplicas}/{.spec.replicas}')
    [[ -n "${rr%%/*}" && "${rr%%/*}" == "${rr##*/}" ]] && ok "router-default Ready $rr" || fail "router-default Ready $rr (rolling 재기동 전 정상화 필요)"
    [[ -s "$H2B/ingress-config.before-h2.yaml" ]] && ok "사전 백업 있음: $H2B" || fail "사전 백업 없음(backup 먼저)"
    [[ -s "$AFFECTED" ]] && info "기존 개별 인증서 Route $(wc -l < "$AFFECTED")개(서비스 담당자 공지): $AFFECTED"

    step "인증서"
    [[ -f "$H2_CERT" && -f "$H2_KEY" && -f "$H2_CA" ]] || die "H2_CERT·H2_KEY·H2_CA 파일이 필요합니다."
    chmod 600 "$H2_KEY"
    openssl x509 -in "$H2_CERT" -noout -subject -enddate -ext subjectAltName | sed 's/^/  /'
    [[ "$(openssl x509 -in "$H2_CERT" -noout -pubkey | sha256sum)" == "$(openssl pkey -in "$H2_KEY" -pubout | sha256sum)" ]] && ok "인증서·키 일치" || fail "인증서·키 불일치"
    openssl verify -CAfile "$H2_CA" "$H2_CERT" >/dev/null && ok "CA 체인 검증" || fail "CA 체인 검증 실패"
    openssl x509 -in "$H2_CERT" -noout -checkend $((30 * 86400)) >/dev/null && ok "만료 30일 이상 남음" || warn "30일 이내 만료"

    step "대상 Route(H2_ROUTES)"
    : > "$EVID/h2-target-routes.txt"
    while read -r r; do
      j=$(oc -n "${r%%/*}" get route "${r##*/}" -o json 2>/dev/null) || { fail "$r 없음"; continue; }
      h=$(jq -r '.spec.host' <<<"$j"); term=$(jq -r '.spec.tls.termination // "none"' <<<"$j")
      owner=$(jq -r '[(.metadata.ownerReferences // [])[].kind] | join(",")' <<<"$j")
      cur=$(jq -r 'if (.spec.tls.certificate // "") != "" then "개별인증서" elif .spec.tls.externalCertificate != null then "외부Secret" else "기본인증서" end' <<<"$j")
      printf '%s\t%s\t%s\t%s\t%s\n' "$r" "$h" "$term" "$cur" "${owner:-none}" >> "$EVID/h2-target-routes.txt"
      [[ "$term" == "edge" || "$term" == "reencrypt" ]] && ok "$r $h termination=$term ($cur)" || fail "$r termination=$term (edge·reencrypt만 대상)"
      [[ -z "$owner" ]] || fail "$r ownerReferences=$owner (Operator·Ingress가 되돌림 → H2_ROUTES에서 제외)"
      [[ "$cur" == "외부Secret" ]] && warn "$r spec.tls.externalCertificate 사용 중 → 인증서는 Secret에서 바꾼다"
      [[ -s "$(route_backup "$r")" ]] || fail "$r 백업 없음(backup 먼저)"
      openssl x509 -in "$H2_CERT" -noout -checkhost "$h" 2>/dev/null | grep -q 'does match' && ok "$h 인증서 SAN 일치" || fail "$h 인증서 SAN 불일치"
    done < <(targets)
    pt=$(oc get route -A -o json | jq -r '.items[] | select(.spec.tls.termination == "passthrough") | "\(.metadata.namespace)/\(.metadata.name) \(.spec.host)"')
    [[ -z "$pt" ]] || { warn "passthrough Route 있음(같은 인증서 도메인이면 HTTP/2 연결 재사용 영향 확인)"; sed 's/^/    /' <<<"$pt"; }
    ;;

  enable)
    step "전역 HTTP/2 annotation"
    [[ -s "$H2B/ingress-config.before-h2.yaml" ]] || die "사전 백업이 없습니다(backup 먼저)."
    mkdir -p "$(dirname "$PATCH_GLOBAL")"
    printf 'metadata:\n  annotations:\n    %s: "true"\n' "$ANN" > "$PATCH_GLOBAL"
    oc patch ingresses.config/cluster --type=merge --patch-file="$PATCH_GLOBAL" --dry-run=server -o jsonpath='{.metadata.annotations}{"\n"}' >/dev/null && ok "서버 dry-run 통과" || die "서버 dry-run 실패"
    if is_dry_run; then info "DRY_RUN=true: 적용하지 않습니다(적용 시 router-default rolling 재기동)."; summary; exit $?; fi
    confirm "전역 HTTP/2를 켭니까? router-default가 rolling 재기동됩니다."
    oc patch ingresses.config/cluster --type=merge --patch-file="$PATCH_GLOBAL"
    wait_router false
    oc -n openshift-ingress get pods -o wide | grep router- || true
    v=$(curl -sk --http2 -o /dev/null -m 10 -w '%{http_version} %{http_code}' "https://console-openshift-console.${APPS_DOMAIN}/" || true)
    [[ "$v" == "1.1 "* ]] && ok "console(기본 인증서) HTTP $v" || warn "console HTTP ${v:-연결 실패}"
    ;;

  cert)
    need_var H2_ROUTES H2_CERT H2_KEY H2_CA
    step "기존 Route 인증서 변경"
    [[ "$(http2_env router-default)" == "false" ]] || warn "router-default HTTP/2 미적용(enable 먼저). 인증서만 바뀌고 HTTP/1.1로 동작"
    mapfile -t list < <(targets "$@")
    [[ "${FIRST_ONLY:-false}" == "true" ]] && list=("${list[0]}")
    for r in "${list[@]}"; do
      ns=${r%%/*}; rt=${r##*/}
      [[ -s "$(route_backup "$r")" ]] || { fail "$r 백업 없음(backup 먼저)"; continue; }
      [[ -z "$(jq -r '[(.metadata.ownerReferences // [])[].kind] | join(",")' "$(route_backup "$r")")" ]] || { fail "$r ownerReferences 있음 → 건너뜀"; continue; }
      p=$(mktemp "$WORK_ROOT/certs/.h2-patch-XXXXXX.json")
      chmod 600 "$p"; TMP_PATCH=$p
      jq -n --rawfile c "$H2_CERT" --rawfile k "$H2_KEY" --rawfile ca "$H2_CA" '{spec:{tls:{certificate:$c, key:$k, caCertificate:$ca}}}' > "$p"
      if oc -n "$ns" patch route "$rt" --type=merge --patch-file="$p" --dry-run=server -o name >/dev/null; then
        ok "$r 서버 dry-run 통과"
        if ! is_dry_run; then
          confirm "$r 인증서를 바꿉니까?"
          oc -n "$ns" patch route "$rt" --type=merge --patch-file="$p" >/dev/null && ok "$r 인증서 변경" || fail "$r 인증서 변경 실패"
        fi
      else
        fail "$r 서버 dry-run 실패"
      fi
      rm -f "$p"
      # 라우터가 새 인증서를 거부하면(ExtendedValidationFailed 등) Admitted=False가 된다.
      if ! is_dry_run; then
        sleep 10
        adm=$(oc -n "$ns" get route "$rt" -o jsonpath='{range .status.ingress[*]}{.routerName}{"="}{.conditions[?(@.type=="Admitted")].status}{"/"}{.conditions[?(@.type=="Admitted")].reason}{" "}{end}')
        [[ -z "$adm" || "$adm" == *=False* ]] && fail "$r Admitted 아님: ${adm:-상태 없음}" || ok "$r Admitted: $adm"
      fi
    done
    ;;

  verify)
    need_var H2_ROUTES H2_CA
    step "인증서를 바꾼 Route(HTTP/2 예상)"
    FP=$(cert_fp < "$H2_CERT")
    while read -r r; do
      h=$(oc -n "${r%%/*}" get route "${r##*/}" -o jsonpath='{.spec.host}' 2>/dev/null) || { fail "$r 없음"; continue; }
      if [[ "$(oc -n "${r%%/*}" get route "${r##*/}" -o jsonpath='{.spec.tls.certificate}' | cert_fp)" != "$FP" ]]; then info "$h 인증서 미변경(건너뜀)"; continue; fi
      alpn=$(openssl s_client -connect "$h:443" -servername "$h" -CAfile "$H2_CA" -alpn h2,http/1.1 </dev/null 2>/dev/null | grep -E '^ALPN protocol' || true)
      ver=$(curl -s --http2 --cacert "$H2_CA" -o /dev/null -m 10 -w '%{http_version} %{http_code}' "https://$h/" || true)
      [[ "$alpn" == *h2* && "$ver" == "2 "* && "$ver" != *" 5"* ]] && ok "$h  $alpn  HTTP $ver" || fail "$h  ${alpn:-ALPN 없음}  HTTP ${ver:-연결 실패}"
    done < <(targets)
    step "기본 인증서 Route(HTTP/1.1 예상)·기존 개별 인증서 Route(오류 없음)"
    v=$(curl -sk --http2 -o /dev/null -m 10 -w '%{http_version} %{http_code}' "https://console-openshift-console.${APPS_DOMAIN}/" || true)
    [[ "$v" == "1.1 "* ]] && ok "console(기본 인증서) HTTP $v" || fail "console HTTP ${v:-연결 실패} (1.1 예상)"
    if [[ -s "$AFFECTED" ]]; then
      while read -r h; do
        v=$(curl -sk --http2 -o /dev/null -m 10 -w '%{http_version} %{http_code}' "https://$h/" || true)
        # 연결 실패는 curl이 "0 000"을 출력한다.
        [[ -z "$v" || "$v" == "0 "* || "$v" == *" 000" || "$v" == *" 5"* ]] && fail "$h HTTP ${v:-연결 실패}" || ok "$h HTTP $v"
      done < <(cut -f3 "$AFFECTED")
    else
      info "기존 개별 인증서 Route 없음($AFFECTED)"
    fi
    info "router-default alpn h2 host: $(oc -n openshift-ingress exec deploy/router-default -- grep 'alpn h2' /var/lib/haproxy/conf/cert_config.map 2>/dev/null | awk '{print $NF}' | xargs || true)"
    ;;

  evidence)
    step "증적(개인키 제외) → $EVID"
    oc get ingresses.config/cluster -o yaml > "$EVID/h2-ingress-config.yaml"
    while read -r r; do
      oc -n "${r%%/*}" get route "${r##*/}" -o json | jq 'del(.spec.tls.key) | {name:.metadata.name, namespace:.metadata.namespace, host:.spec.host, tls:.spec.tls, ingress:.status.ingress}' > "$EVID/h2-route-${r%%/*}-${r##*/}.json"
    done < <(targets)
    oc -n openshift-ingress get pod -o wide | grep router- > "$EVID/h2-router-pods.txt" || true
    grep -l 'PRIVATE KEY' "$EVID"/h2-* 2>/dev/null && fail "증적에 개인키 포함" || ok "증적에 개인키 없음"
    left=$(find "$WORK_ROOT/certs" \( -name '.h2-patch-*' -o -name '.h2-restore-*' \) 2>/dev/null | wc -l)
    [[ "$left" == "0" ]] && ok "임시 patch 파일 없음" || fail "임시 patch 파일 ${left}개 남음 → 삭제"
    ;;

  rollback-cert)
    step "원복: Route spec.tls를 백업 값으로"
    confirm "Route 인증서를 원복합니까?"
    while read -r r; do
      b=$(route_backup "$r"); [[ -s "$b" ]] || { fail "$r 백업 없음"; continue; }
      p=$(mktemp "$WORK_ROOT/certs/.h2-restore-XXXXXX.json"); chmod 600 "$p"; TMP_PATCH=$p
      jq '[{op:"replace", path:"/spec/tls", value:.spec.tls}]' "$b" > "$p"
      if is_dry_run; then
        oc -n "${r%%/*}" patch route "${r##*/}" --type=json --patch-file="$p" --dry-run=server -o name >/dev/null && ok "$r 원복 dry-run 통과" || fail "$r 원복 dry-run 실패"
      else
        oc -n "${r%%/*}" patch route "${r##*/}" --type=json --patch-file="$p" >/dev/null && ok "$r 원복" || fail "$r 원복 실패"
      fi
      rm -f "$p"
    done < <(targets "$@")
    ;;

  rollback-global)
    step "원복: 전역 annotation 제거"
    if grep -q 'default-enable-http2' "$H2B/ingress-config.before-h2.yaml" 2>/dev/null; then
      die "적용 전에도 annotation이 있었습니다. 백업 값으로 수동 원복하세요: $H2B/ingress-config.before-h2.yaml"
    fi
    confirm "전역 HTTP/2를 끕니까? router-default가 rolling 재기동됩니다."
    run oc annotate ingresses.config/cluster "${ANN}-"
    is_dry_run || wait_router true
    ;;

  *) die "사용: $0 backup|precheck|enable|cert [ns/route..]|verify|evidence|rollback-cert [ns/route..]|rollback-global" ;;
esac
summary
