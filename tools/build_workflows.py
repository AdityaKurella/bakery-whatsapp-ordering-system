#!/usr/bin/env python3
"""Builds the six importable n8n workflow exports from src/*.js. Run: python3 tools/build_workflows.py
Node type versions deliberately use versions that already exist in n8n 1.x and are retained in 2.x.
They have NOT been verified against a running n8n 2.22.6 (see README 'Validation performed')."""
import json, uuid, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC, OUT = ROOT / "src", ROOT / "workflows"
LIB = (SRC / "lib_common.js").read_text()
NS = uuid.UUID("6f1d5c2e-0b7a-4c1e-9a55-0a0b0c0d0e0f")

PG_CRED = {"postgres": {"name": "Bakery Postgres"}}
WA_CRED = {"httpHeaderAuth": {"name": "WhatsApp Cloud Bearer"}}
AI_CRED = {"httpHeaderAuth": {"name": "Anthropic API Key"}}
STAFF_CRED = {"httpHeaderAuth": {"name": "Bakery Staff Webhook Key"}}
PH_C = "REPLACE_WITH_WORKFLOW_C_ID"
PH_D = "REPLACE_WITH_WORKFLOW_D_ID"


def code_src(name):
    s = (SRC / name).read_text()
    return s.replace("//@@LIB@@", LIB)


class WF:
    def __init__(self, name, settings=None):
        self.name, self.nodes, self.conns, self.col = name, [], {}, {}
        self.settings = {"executionOrder": "v1", "saveDataSuccessExecution": "none", "saveDataErrorExecution": "all",
                         "saveManualExecutions": True}
        if settings:
            self.settings.update(settings)

    def add(self, name, type_, ver, params, x, y, creds=None, **extra):
        n = {"parameters": params, "id": str(uuid.uuid5(NS, self.name + "|" + name)), "name": name, "type": type_,
             "typeVersion": ver, "position": [x, y]}
        if creds:
            n["credentials"] = creds
        n.update(extra)
        self.nodes.append(n)
        return name

    def link(self, a, b, out=0):
        self.conns.setdefault(a, {"main": []})
        m = self.conns[a]["main"]
        while len(m) <= out:
            m.append([])
        m[out].append({"node": b, "type": "main", "index": 0})

    def export(self, fname):
        d = {"name": self.name, "nodes": self.nodes, "pinData": {}, "connections": self.conns, "active": False,
             "settings": self.settings, "tags": []}
        (OUT / fname).write_text(json.dumps(d, indent=2, ensure_ascii=False) + "\n")


# ---- node factories -------------------------------------------------------
def code(w, name, src, x, y, **kw):
    return w.add(name, "n8n-nodes-base.code", 2, {"mode": "runOnceForAllItems", "language": "javaScript", "jsCode": code_src(src)}, x, y, **kw)


def pg(w, name, query, repl, x, y, retry=False, err_out=False):
    p = {"operation": "executeQuery", "query": query, "options": {}}
    if repl:
        p["options"]["queryReplacement"] = repl
    extra = {}
    if retry:
        extra.update({"retryOnFail": True, "maxTries": 3, "waitBetweenTries": 1000})
    if err_out:
        extra["onError"] = "continueErrorOutput"
    return w.add(name, "n8n-nodes-base.postgres", 2.5, p, x, y, creds=PG_CRED, **extra)


def cond_bool(expr, cid):
    return {"conditions": {"options": {"caseSensitive": True, "leftValue": "", "typeValidation": "strict", "version": 2},
                           "conditions": [{"id": cid, "leftValue": expr, "rightValue": "",
                                           "operator": {"type": "boolean", "operation": "true", "singleValue": True}}],
                           "combinator": "and"}, "options": {}}


def iff(w, name, expr, x, y):
    return w.add(name, "n8n-nodes-base.if", 2.2, cond_bool(expr, str(uuid.uuid5(NS, w.name + name + "cond"))), x, y)


def respond_text(w, name, body, code_, x, y, ctype=None):
    opts = {"responseCode": code_}
    if ctype:
        opts["responseHeaders"] = {"entries": [{"name": "Content-Type", "value": ctype}]}
    return w.add(name, "n8n-nodes-base.respondToWebhook", 1.4, {"respondWith": "text", "responseBody": body, "options": opts}, x, y)


def respond_json(w, name, body, code_, x, y):
    return w.add(name, "n8n-nodes-base.respondToWebhook", 1.4, {"respondWith": "json", "responseBody": body, "options": {"responseCode": code_}}, x, y)


def webhook(w, name, method, path, x, y, raw=False, auth=None, creds=None):
    opts = {"rawBody": True} if raw else {}
    p = {"httpMethod": method, "path": path, "authentication": auth or "none", "responseMode": "responseNode", "options": opts}
    return w.add(name, "n8n-nodes-base.webhook", 2, p, x, y, creds=creds, webhookId=str(uuid.uuid5(NS, w.name + name + path)))


def exec_wf(w, name, placeholder, wait, x, y):
    return w.add(name, "n8n-nodes-base.executeWorkflow", 1.2,
                 {"workflowId": {"__rl": True, "mode": "id", "value": placeholder},
                  "options": {"waitForSubWorkflow": wait}}, x, y)


def exec_trigger(w, name, x, y):
    return w.add(name, "n8n-nodes-base.executeWorkflowTrigger", 1.1, {"inputSource": "passthrough"}, x, y)


def http_alert(w, name, x, y):
    return w.add(name, "n8n-nodes-base.httpRequest", 4.2,
                 {"method": "POST", "url": "={{ $env.ALERT_WEBHOOK_URL }}", "sendBody": True, "specifyBody": "json",
                  "jsonBody": "={{ JSON.stringify($json.payload) }}", "options": {"timeout": 10000}},
                 x, y, onError="continueRegularOutput")


def note(w, text, x, y, wd=420, ht=240):
    return w.add("Setup Notes", "n8n-nodes-base.stickyNote", 1, {"content": text, "height": ht, "width": wd}, x, y)


# ---- Workflow A -----------------------------------------------------------
def build_a():
    w = WF("A - WhatsApp Webhook Verification (GET)")
    webhook(w, "Meta Verification GET", "GET", "whatsapp-bakery", 0, 200)
    code(w, "Check Verification Request", "verify_get.js", 260, 200)
    iff(w, "Verification OK?", "={{ $json.ok }}", 520, 200)
    respond_text(w, "Respond Challenge", "={{ $json.challenge }}", 200, 780, 120, "text/plain; charset=utf-8")
    respond_text(w, "Respond Forbidden", "Forbidden", 403, 780, 300, "text/plain; charset=utf-8")
    w.link("Meta Verification GET", "Check Verification Request")
    w.link("Check Verification Request", "Verification OK?")
    w.link("Verification OK?", "Respond Challenge", 0)
    w.link("Verification OK?", "Respond Forbidden", 1)
    note(w, "**Workflow A: Meta GET verification**\nSame URL as Workflow B (different HTTP method).\nRequires n8n env: META_VERIFY_TOKEN (>=16 chars) and N8N_BLOCK_ENV_ACCESS_IN_NODE=false.\nMeta callback URL (production): https://YOUR-HOST/webhook/whatsapp-bakery\nTest URL (editor 'Listen'): /webhook-test/whatsapp-bakery\nActivate only after README step 7.", 0, -120)
    w.export("A_whatsapp_webhook_verification.json")


# ---- Workflow B -----------------------------------------------------------
def build_b():
    w = WF("B - WhatsApp Incoming Message Intake (POST)")
    webhook(w, "Meta Webhook POST", "POST", "whatsapp-bakery", 0, 240, raw=True)
    code(w, "Verify Signature", "verify_signature.js", 260, 240)
    iff(w, "Signature Valid?", "={{ $json.valid }}", 520, 240)
    respond_text(w, "Respond Rejected", "Forbidden", 403, 780, 460, "text/plain; charset=utf-8")
    code(w, "Normalize Events", "normalize_events.js", 780, 160)
    pg(w, "Enqueue Events", "SELECT bakery.fn_enqueue_events($1::jsonb) AS r", "={{ [ JSON.stringify($json.events) ] }}", 1040, 160, err_out=True)
    respond_text(w, "Respond Retry Later", "Service Unavailable", 503, 1300, 380, "text/plain; charset=utf-8")
    respond_text(w, "Respond OK", "OK", 200, 1300, 160, "text/plain; charset=utf-8")
    code(w, "Fan Out Events", "fan_out.js", 1560, 160)
    exec_wf(w, "Process Event (Workflow C)", PH_C, False, 1820, 160)
    w.link("Meta Webhook POST", "Verify Signature")
    w.link("Verify Signature", "Signature Valid?")
    w.link("Signature Valid?", "Normalize Events", 0)
    w.link("Signature Valid?", "Respond Rejected", 1)
    w.link("Normalize Events", "Enqueue Events")
    w.link("Enqueue Events", "Respond OK", 0)
    w.link("Enqueue Events", "Respond Retry Later", 1)
    w.link("Respond OK", "Fan Out Events")
    w.link("Fan Out Events", "Process Event (Workflow C)")
    note(w, "**Workflow B: POST intake**\nOrder of operations: verify HMAC on raw body -> store events durably (idempotent) -> ACK 200 -> process.\nIf the database write fails we answer 503 so Meta redelivers.\nRequires n8n env: META_APP_SECRET, META_PHONE_NUMBER_ID, NODE_FUNCTION_ALLOW_BUILTIN=crypto, N8N_BLOCK_ENV_ACCESS_IN_NODE=false.\nSET the 'Process Event' node to Workflow C (placeholder REPLACE_WITH_WORKFLOW_C_ID).\nCredential: 'Bakery Postgres'.", 0, -140, 560, 260)
    w.export("B_whatsapp_incoming_intake.json")


# ---- Workflow C -----------------------------------------------------------
def build_c():
    w = WF("C - Conversation and Ordering Engine")
    exec_trigger(w, "Called With event_id", 0, 240)
    pg(w, "Claim Event", "SELECT bakery.fn_claim_event($1::bigint) AS ev", "={{ [ $json.event_id ] }}", 240, 240)
    pg(w, "Load Context", "SELECT bakery.fn_get_settings() AS settings, bakery.fn_session_hint($1::text) AS hint", "={{ [ $json.ev.wa_id ] }}", 480, 240)
    code(w, "Parse Intent", "parse_intent.js", 720, 240)
    iff(w, "Needs AI?", "={{ $json.needs_ai }}", 960, 240)
    w.add("Call LLM", "n8n-nodes-base.httpRequest", 4.2,
          {"method": "POST", "url": "https://api.anthropic.com/v1/messages", "authentication": "genericCredentialType",
           "genericAuthType": "httpHeaderAuth", "sendHeaders": True,
           "headerParameters": {"parameters": [{"name": "anthropic-version", "value": "2023-06-01"}]},
           "sendBody": True, "specifyBody": "json", "jsonBody": "={{ JSON.stringify($json.ai_request) }}",
           "options": {"timeout": 15000}}, 1200, 100, creds=AI_CRED, onError="continueRegularOutput")
    code(w, "Validate AI Output", "validate_ai.js", 1440, 100)
    pg(w, "Apply Intent", "SELECT bakery.fn_handle_inbound($1::bigint, $2::jsonb) AS result",
       "={{ [ $('Claim Event').first().json.ev.event_id, JSON.stringify($json.intent) ] }}", 1700, 240, retry=True)
    code(w, "Render Replies", "render_replies.js", 1940, 240)
    pg(w, "Enqueue Replies", "SELECT bakery.fn_enqueue_replies($1::bigint, $2::jsonb) AS r",
       "={{ [ $json.event_id, JSON.stringify($json.messages) ] }}", 2180, 240, retry=True)
    exec_wf(w, "Dispatch Now (Workflow D)", PH_D, False, 2420, 240)
    for a, b in [("Called With event_id", "Claim Event"), ("Claim Event", "Load Context"), ("Load Context", "Parse Intent"),
                 ("Parse Intent", "Needs AI?"), ("Call LLM", "Validate AI Output"), ("Validate AI Output", "Apply Intent"),
                 ("Apply Intent", "Render Replies"), ("Render Replies", "Enqueue Replies"), ("Enqueue Replies", "Dispatch Now (Workflow D)")]:
        w.link(a, b)
    w.link("Needs AI?", "Call LLM", 0)
    w.link("Needs AI?", "Apply Intent", 1)
    note(w, "**Workflow C: conversation engine**\nCalled by B (new events) and E (replays) with {event_id}.\nAll state, cart, price and order logic is in PostgreSQL functions (bakery.fn_handle_inbound).\nThe LLM branch is OFF unless bakery_settings.ai_enabled = true AND ai_model is set; it can never confirm, cancel, price or set details.\nSET 'Dispatch Now' to Workflow D (placeholder REPLACE_WITH_WORKFLOW_D_ID).\nCredentials: 'Bakery Postgres', 'Anthropic API Key' (Header Auth: x-api-key) only if AI is enabled.", 0, -160, 620, 280)
    w.export("C_conversation_ordering_engine.json")


# ---- Workflow D -----------------------------------------------------------
def build_d():
    w = WF("D - Order Notifications and Status Dispatcher")
    exec_trigger(w, "Dispatch Now (called by C)", 0, 140)
    w.add("Every Minute (safety net)", "n8n-nodes-base.scheduleTrigger", 1.2, {"rule": {"interval": [{"field": "minutes", "minutesInterval": 1}]}}, 0, 300)
    webhook(w, "Staff Status Webhook", "POST", "bakery-order-status", 0, 520, auth="headerAuth", creds=STAFF_CRED)
    code(w, "Validate Staff Request", "validate_staff.js", 260, 520)
    iff(w, "Staff Request Valid?", "={{ $json.valid }}", 520, 520)
    respond_json(w, "Respond Staff Invalid", "={{ { ok: false, error: $json.error } }}", 400, 780, 700)
    pg(w, "Apply Order Update",
       "SELECT CASE WHEN $3::text <> '' THEN bakery.fn_set_payment_status($1::text, $3::text, $4::text, $5::text) ELSE bakery.fn_set_order_status($1::text, $2::text, $4::text, $5::text) END AS r",
       "={{ [ $json.order_ref, $json.status, $json.payment_status, $json.actor, $json.note ] }}", 780, 520)
    respond_json(w, "Respond Staff Result", "={{ $json.r }}", 200, 1040, 520)
    pg(w, "Load Settings", "SELECT bakery.fn_get_settings() AS settings", None, 1300, 240)
    pg(w, "Claim Batch", "SELECT bakery.fn_outbox_claim(10) AS item", None, 1540, 240)
    code(w, "Render Outbox", "render_outbox.js", 1780, 240)
    iff(w, "Can Send?", "={{ $json.send }}", 2020, 240)
    w.add("Send WhatsApp Message", "n8n-nodes-base.httpRequest", 4.2,
          {"method": "POST", "url": "={{ $json.url }}", "authentication": "genericCredentialType", "genericAuthType": "httpHeaderAuth",
           "sendBody": True, "specifyBody": "json", "jsonBody": "={{ JSON.stringify($json.body) }}",
           "options": {"timeout": 15000, "response": {"response": {"fullResponse": True, "neverError": True}},
                       "batching": {"batch": {"batchSize": 1, "batchInterval": 150}}}},
          2260, 160, creds=WA_CRED, onError="continueRegularOutput", retryOnFail=False)
    code(w, "Classify Result", "classify_send.js", 2500, 160)
    pg(w, "Record Result", "SELECT bakery.fn_outbox_record($1::bigint, $2::text, $3::text, $4::text, $5::text) AS r",
       "={{ [ $json.id, $json.outcome, $json.code, $json.text, $json.provider_id ] }}", 2760, 240, retry=True)
    w.link("Dispatch Now (called by C)", "Load Settings")
    w.link("Every Minute (safety net)", "Load Settings")
    w.link("Staff Status Webhook", "Validate Staff Request")
    w.link("Validate Staff Request", "Staff Request Valid?")
    w.link("Staff Request Valid?", "Apply Order Update", 0)
    w.link("Staff Request Valid?", "Respond Staff Invalid", 1)
    w.link("Apply Order Update", "Respond Staff Result")
    w.link("Respond Staff Result", "Load Settings")
    w.link("Load Settings", "Claim Batch")
    w.link("Claim Batch", "Render Outbox")
    w.link("Render Outbox", "Can Send?")
    w.link("Can Send?", "Send WhatsApp Message", 0)
    w.link("Can Send?", "Record Result", 1)
    w.link("Send WhatsApp Message", "Classify Result")
    w.link("Classify Result", "Record Result")
    note(w, "**Workflow D: outbox dispatcher + staff status API**\nSends every queued WhatsApp message (customer replies, order confirmations, bakery alerts). Orders are already committed before anything is sent.\nStaff API: POST /webhook/bakery-order-status  header per credential 'Bakery Staff Webhook Key'\nbody {\"order_ref\":\"BK-...\",\"status\":\"PREPARING\"} or {\"order_ref\":\"BK-...\",\"payment_status\":\"PAID\",\"actor\":\"name\"}\nRequires n8n env: META_PHONE_NUMBER_ID, WHATSAPP_API_VERSION (e.g. v21.0 - check Meta docs for a currently supported version).\nCredentials: 'Bakery Postgres', 'WhatsApp Cloud Bearer' (Header Auth: Authorization = Bearer <token>), 'Bakery Staff Webhook Key'.", 0, -220, 640, 300)
    w.export("D_notifications_status_dispatcher.json")


# ---- Workflow E -----------------------------------------------------------
def build_e():
    w = WF("E - Scheduled Maintenance and Recovery")
    w.add("Every 5 Minutes", "n8n-nodes-base.scheduleTrigger", 1.2, {"rule": {"interval": [{"field": "cronExpression", "expression": "*/5 * * * *"}]}}, 0, 200)
    pg(w, "Run Maintenance", "SELECT bakery.fn_maintenance() AS r", None, 260, 200)
    code(w, "Replay IDs", "replay_ids.js", 520, 80)
    exec_wf(w, "Replay Event (Workflow C)", PH_C, False, 780, 80)
    iff(w, "Alert Needed?", "={{ $json.r.alert }}", 520, 320)
    code(w, "Build Alert", "build_alert.js", 780, 320)
    iff(w, "Alert URL Set?", "={{ $json.has_url }}", 1040, 320)
    http_alert(w, "Send Alert", 1300, 320)
    w.add("Manual: List Dead Letters", "n8n-nodes-base.manualTrigger", 1, {}, 0, 560)
    pg(w, "Query Dead Letters", "SELECT * FROM bakery.v_dead_letters ORDER BY created_at LIMIT 100", None, 260, 560)
    w.link("Every 5 Minutes", "Run Maintenance")
    w.link("Run Maintenance", "Replay IDs")
    w.link("Run Maintenance", "Alert Needed?")
    w.link("Replay IDs", "Replay Event (Workflow C)")
    w.link("Alert Needed?", "Build Alert", 0)
    w.link("Build Alert", "Alert URL Set?")
    w.link("Alert URL Set?", "Send Alert", 0)
    w.link("Manual: List Dead Letters", "Query Dead Letters")
    note(w, "**Workflow E: maintenance**\nEvery 5 min: expire abandoned carts, unstick outbox rows, replay stale inbound events (max attempts then dead-letter), apply retention, raise de-duplicated alerts. A failing database makes this workflow fail -> error workflow F alerts.\nManual branch lists dead letters. Replay with SQL: SELECT bakery.fn_replay_dead_event(<id>); SELECT bakery.fn_requeue_outbox(<id>);\nSET 'Replay Event' to Workflow C (REPLACE_WITH_WORKFLOW_C_ID). Optional env: ALERT_WEBHOOK_URL.", 0, -200, 640, 240)
    w.export("E_maintenance_recovery.json")


# ---- Workflow F -----------------------------------------------------------
def build_f():
    w = WF("F - Error Handler and Monitoring")
    w.add("Error Trigger", "n8n-nodes-base.errorTrigger", 1, {}, 0, 200)
    code(w, "Redact and Classify", "error_redact.js", 260, 200)
    pg(w, "Log Error", "INSERT INTO bakery.error_log(workflow_name, execution_id, node_name, classification, message, order_ref) VALUES ($1, $2, $3, $4, $5, $6)",
       "={{ [ $json.workflow_name, $json.execution_id, $json.node_name, $json.classification, $json.message, $json.order_ref ] }}", 520, 120)
    w.nodes[-1]["onError"] = "continueRegularOutput"
    iff(w, "Alert URL Set?", "={{ $json.has_url }}", 520, 320)
    http_alert(w, "Send Alert", 780, 320)
    w.link("Error Trigger", "Redact and Classify")
    w.link("Redact and Classify", "Log Error")
    w.link("Redact and Classify", "Alert URL Set?")
    w.link("Alert URL Set?", "Send Alert", 0)
    note(w, "**Workflow F: error handler**\nIn workflows A-E open Settings -> 'Error Workflow' and pick this workflow (do not set it on F itself).\nClassifies TRANSIENT / PERMANENT / UNKNOWN, redacts tokens and numbers, logs to bakery.error_log, alerts via ALERT_WEBHOOK_URL (Slack/Discord-compatible).\nIt does NOT re-run failed executions: recovery is data-driven (E replays events, D retries notifications with backoff). Permanent failures are never retried automatically.", 0, -160, 600, 220)
    w.export("F_error_handler_monitoring.json")


if __name__ == "__main__":
    OUT.mkdir(exist_ok=True)
    for f in (build_a, build_b, build_c, build_d, build_e, build_f):
        f()
    print("built:", sorted(p.name for p in OUT.glob("*.json")))
