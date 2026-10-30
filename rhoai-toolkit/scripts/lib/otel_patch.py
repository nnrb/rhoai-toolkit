#!/usr/bin/env python3
# OTel 적용 patch·원복 patch 생성(82-otel-models.sh가 호출). 2026-10 작업계획서 rev5~rev7 OTel patch 생성 코드와 같다.
#   사용: otel_patch.py <isvc|llmisvc> <모델 백업 JSON> <증적 Pod JSON> <OTLP base http://...:4318> <ns/Instrumentation> <service.name> <sampling ratio> <patch 출력> <rollback 출력>
#   - ISVC: predictor annotations에 Python 자동 주입, kserve-container env(OTEL_*·NO_PROXY), args에 --otlp-traces-endpoint
#   - LLMI: spec annotations, main container env, VLLM_ADDITIONAL_ARGS에 --otlp-traces-endpoint
#   - 원복 patch는 test op로 적용 후 값이 바뀌지 않았을 때만 되돌린다.
#   - 여러 노드(workerSpec)·P/D 분리·기존 주입·기존 native tracing·valueFrom env는 수동 검토 대상이라 중단(exit 1)한다.
import json
import sys

kind, before_f, pod_f, ep, inst, svc, ratio, patch_f, rollback_f = sys.argv[1:10]
INJ = "instrumentation.opentelemetry.io/inject-python"
CNS = "instrumentation.opentelemetry.io/container-names"
obj = json.load(open(before_f, encoding="utf-8"))
pod = json.load(open(pod_f, encoding="utf-8"))
spec = obj["spec"]
if not (ep.startswith("http://") and ep.endswith(":4318")):
    sys.exit("endpoint must be http://...:4318 without /v1/traces")
if not 0 <= float(ratio) <= 1:
    sys.exit("invalid sampling ratio")
if kind == "isvc":
    pred = spec["predictor"]
    owner, opath, cname = pred, "/spec/predictor", "kserve-container"
    if pred.get("workerSpec"):
        sys.exit("multi-node ISVC: per-worker validation required, do not use this patch")
    if isinstance(pred.get("model"), dict):
        c, cpath, custom = pred["model"], "/spec/predictor/model", False
    else:
        idx = [i for i, x in enumerate(pred.get("containers", [])) if x.get("name") == cname]
        if len(idx) != 1:
            sys.exit("expected predictor.model or exactly one kserve-container")
        c, cpath, custom = pred["containers"][idx[0]], "/spec/predictor/containers/%d" % idx[0], True
else:
    owner, opath, cname, custom = spec, "/spec", "main", False
    if spec.get("prefill") or spec.get("worker"):
        sys.exit("P/D or multi-node LLMI: per-role validation required, do not use this patch")
    ctrs = spec.get("template", {}).get("containers", [])
    idx = [i for i, x in enumerate(ctrs) if x.get("name") == cname]
    if len(idx) != 1:
        sys.exit("expected exactly one main container in spec.template.containers")
    c, cpath = ctrs[idx[0]], "/spec/template/containers/%d" % idx[0]
eff = next((x for x in pod["spec"]["containers"] if x["name"] == cname), None)
if eff is None:
    sys.exit("runtime container not found in evidence Pod")
if owner.get("annotations", {}).get(INJ, "false") != "false":
    sys.exit("existing Python injection: inspect and merge manually")
if pod.get("metadata", {}).get("annotations", {}).get(INJ, "false") != "false":
    sys.exit("Pod already inherits Python injection: inspect its source")
eenv = {e["name"]: e for e in eff.get("env", [])}
oenv = {e["name"]: e for e in c.get("env", [])}
if "--otlp-traces-endpoint" in " ".join(eff.get("args", []) + [eenv.get("VLLM_ADDITIONAL_ARGS", {}).get("value", "")]):
    sys.exit("existing native tracing argument: inspect before changing")
proxy = []
for key in ("NO_PROXY", "no_proxy"):
    v = oenv.get(key, eenv.get(key, {}))
    if "valueFrom" in v:
        sys.exit("NO_PROXY uses valueFrom: merge manually")
    proxy += v.get("value", "").split(",")
no_proxy = ",".join(dict.fromkeys(x.strip() for x in proxy + [".svc", ".svc.cluster.local"] if x.strip()))
trace_arg = "--otlp-traces-endpoint=" + ep + "/v1/traces"
upd = {"OTEL_SERVICE_NAME": svc, "OTEL_EXPORTER_OTLP_ENDPOINT": ep,
       "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT": ep + "/v1/traces",
       "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf", "OTEL_EXPORTER_OTLP_TRACES_PROTOCOL": "http/protobuf",
       "OTEL_TRACES_EXPORTER": "otlp", "OTEL_METRICS_EXPORTER": "none", "OTEL_LOGS_EXPORTER": "none",
       "OTEL_TRACES_SAMPLER": "parentbased_traceidratio", "OTEL_TRACES_SAMPLER_ARG": ratio,
       "NO_PROXY": no_proxy, "no_proxy": no_proxy}
fields = []
if kind == "llmisvc":
    v = oenv.get("VLLM_ADDITIONAL_ARGS", eenv.get("VLLM_ADDITIONAL_ARGS", {}))
    if "valueFrom" in v:
        sys.exit("VLLM_ADDITIONAL_ARGS uses valueFrom: merge manually")
    upd["VLLM_ADDITIONAL_ARGS"] = (v.get("value", "") + " " + trace_arg).strip()
else:
    if custom and "args" not in c:
        sys.exit("custom kserve-container without args: new args would replace the image CMD, review manually")
    fields.append((cpath + "/args", c.get("args"), list(c.get("args", [])) + [trace_arg]))
env = [{"name": e["name"], "value": upd[e["name"]]} if e["name"] in upd else e for e in c.get("env", [])]
env += [{"name": k, "value": v} for k, v in upd.items() if k not in oenv]
fields.append((cpath + "/env", c.get("env"), env))
ann = dict(owner.get("annotations", {}))
ann.update({INJ: inst, CNS: cname})
fields.append((opath + "/annotations", owner.get("annotations"), ann))
patch, rollback = [], []
for p, b, a in fields:
    if b is None:
        patch.append({"op": "add", "path": p, "value": a})
        rollback += [{"op": "test", "path": p, "value": a}, {"op": "remove", "path": p}]
    else:
        patch += [{"op": "test", "path": p, "value": b}, {"op": "replace", "path": p, "value": a}]
        rollback += [{"op": "test", "path": p, "value": a}, {"op": "replace", "path": p, "value": b}]
open(patch_f, "w", encoding="utf-8").write(json.dumps(patch, ensure_ascii=False, indent=2))
open(rollback_f, "w", encoding="utf-8").write(json.dumps(rollback, ensure_ascii=False, indent=2))
print("created", patch_f, rollback_f)
