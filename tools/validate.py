#!/usr/bin/env python3
"""Static validation of the workflow exports. This is NOT an n8n import test."""
import json, re, sys, subprocess, tempfile, pathlib
ROOT = pathlib.Path(__file__).resolve().parent.parent
# type -> versions this project uses (versions exist in n8n 1.x and are retained in 2.x; UNVERIFIED against a 2.22.6 install)
ALLOWED = {"n8n-nodes-base.webhook": {2}, "n8n-nodes-base.code": {2}, "n8n-nodes-base.if": {2.2}, "n8n-nodes-base.respondToWebhook": {1.4},
           "n8n-nodes-base.postgres": {2.5}, "n8n-nodes-base.httpRequest": {4.2}, "n8n-nodes-base.executeWorkflow": {1.2},
           "n8n-nodes-base.executeWorkflowTrigger": {1.1}, "n8n-nodes-base.scheduleTrigger": {1.2}, "n8n-nodes-base.errorTrigger": {1},
           "n8n-nodes-base.manualTrigger": {1}, "n8n-nodes-base.stickyNote": {1}}
TRIGGERS = {"n8n-nodes-base.webhook", "n8n-nodes-base.executeWorkflowTrigger", "n8n-nodes-base.scheduleTrigger", "n8n-nodes-base.errorTrigger", "n8n-nodes-base.manualTrigger"}
ENV_OK = {"META_VERIFY_TOKEN", "META_APP_SECRET", "META_PHONE_NUMBER_ID", "WHATSAPP_API_VERSION", "ALERT_WEBHOOK_URL"}
errs, warns = [], []
def top_level_count(expr):
    m = re.search(r"\[(.*)\]\s*\}\}\s*$", expr, re.S)
    if not m: return None
    s, depth, n, q, any_ = m.group(1), 0, 1, None, False
    for ch in s:
        if q:
            if ch == q: q = None
            continue
        if ch in "'\"`": q = ch
        elif ch in "([{": depth += 1
        elif ch in ")]}": depth -= 1
        elif ch == "," and depth == 0: n += 1
        if not ch.isspace(): any_ = True
    return n if any_ else 0
for f in sorted((ROOT / "workflows").glob("*.json")):
    try: d = json.loads(f.read_text())
    except Exception as e: errs.append(f"{f.name}: invalid JSON {e}"); continue
    nodes = d["nodes"]; names = [n["name"] for n in nodes]; ids = [n["id"] for n in nodes]
    if len(set(names)) != len(names): errs.append(f"{f.name}: duplicate node names")
    if len(set(ids)) != len(ids): errs.append(f"{f.name}: duplicate node ids")
    if d.get("active") is not False: errs.append(f"{f.name}: must be inactive")
    for n in nodes:
        t, v = n["type"], n["typeVersion"]
        if t not in ALLOWED: errs.append(f"{f.name}/{n['name']}: type {t} not in allowlist")
        elif v not in ALLOWED[t]: errs.append(f"{f.name}/{n['name']}: version {v} not planned for {t}")
        if t == "n8n-nodes-base.webhook" and "webhookId" not in n: errs.append(f"{f.name}/{n['name']}: no webhookId")
        for c in (n.get("credentials") or {}).values():
            if c.get("id"): errs.append(f"{f.name}/{n['name']}: credential id must not be embedded")
        blob = json.dumps(n)
        for e in re.findall(r"\$env\.([A-Z_]+)", blob):
            if e not in ENV_OK: errs.append(f"{f.name}/{n['name']}: unknown env var {e}")
        if re.search(r"EAA[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|Bearer [A-Za-z0-9]{20,}", blob): errs.append(f"{f.name}/{n['name']}: looks like a secret")
        if t == "n8n-nodes-base.code":
            with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False) as tf:
                tf.write("async function __n(){\n" + n["parameters"]["jsCode"] + "\n}\n")
            r = subprocess.run(["node", "--check", tf.name], capture_output=True, text=True)
            if r.returncode: errs.append(f"{f.name}/{n['name']}: JS syntax: {r.stderr.strip()[:200]}")
        if t == "n8n-nodes-base.postgres":
            q = n["parameters"]["query"]; mx = max([int(x) for x in re.findall(r"\$(\d+)", q)] or [0])
            rep = n["parameters"]["options"].get("queryReplacement")
            cnt = top_level_count(rep) if rep else 0
            if cnt is None or cnt != mx: errs.append(f"{f.name}/{n['name']}: query uses ${mx} params, replacement has {cnt}")
    for src, outs in d["connections"].items():
        if src not in names: errs.append(f"{f.name}: connection from unknown node {src}")
        for lst in outs["main"]:
            for c in lst:
                if c["node"] not in names: errs.append(f"{f.name}: connection to unknown node {c['node']}")
    reach, stack = set(), [n["name"] for n in nodes if n["type"] in TRIGGERS]
    while stack:
        x = stack.pop()
        if x in reach: continue
        reach.add(x)
        for lst in d["connections"].get(x, {}).get("main", []):
            stack += [c["node"] for c in lst]
    for n in nodes:
        if n["type"] != "n8n-nodes-base.stickyNote" and n["name"] not in reach: errs.append(f"{f.name}: node {n['name']} unreachable from a trigger")
    ph = [n["name"] for n in nodes if "REPLACE_WITH" in json.dumps(n.get("parameters", {}))]
    print(f"{f.name}: {len(nodes)} nodes, placeholders to set: {ph or 'none'}")
print("\nERRORS:" if errs else "\nstatic validation passed (structure, JS syntax, query param counts, connections)")
for e in errs: print(" -", e)
sys.exit(1 if errs else 0)
