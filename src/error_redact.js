// Workflow F - classify and redact the failure. No payloads, tokens or phone numbers leave this node.
const e = $input.first().json || {};
const ex = e.execution || {}, wf = e.workflow || {};
const redact = (s) => String(s == null ? '' : s)
  .replace(/Bearer\s+[A-Za-z0-9._\-~+\/=]+/gi, 'Bearer [redacted]')
  .replace(/\bEA[A-Za-z0-9]{20,}\b/g, '[token]').replace(/\bsk-[A-Za-z0-9_\-]{16,}\b/g, '[key]')
  .replace(/sha256=[a-f0-9]{16,}/gi, 'sha256=[redacted]')
  .replace(/[\w.+-]+@[\w-]+\.[\w.-]+/g, '[email]').replace(/\+?\d[\d\s-]{7,}\d/g, '[number]');
const rawMsg = String(ex.error && ex.error.message ? ex.error.message : '');
const ref = (rawMsg.match(/BK-\d{6}-\d{5}-[A-Z0-9]{3}/) || [null])[0];   // order refs are correlation IDs, not personal data; extract before redacting
const msg = redact(rawMsg).slice(0, 400);
const PERM = /\b(400|401|403|404|422)\b|invalid|unauthori[sz]ed|forbidden|violates|constraint|malformed|syntax|not found|credentials|permission denied|REPLACE_WITH/i;
const TRANS = /ETIMEDOUT|ECONNRESET|ECONNREFUSED|EAI_AGAIN|timed? ?out|\b429\b|\b5\d\d\b|temporar|deadlock|too many connections|connection terminated|could not connect/i;
const classification = PERM.test(msg) ? 'PERMANENT' : TRANS.test(msg) ? 'TRANSIENT' : 'UNKNOWN';
const policy = classification === 'TRANSIENT' ? 'Automatic: inbound events are replayed by Workflow E and notifications are retried with backoff by Workflow D; no action unless alerts repeat.'
  : classification === 'PERMANENT' ? 'Manual: fix configuration/data, then replay (see README recovery section). It will NOT be retried automatically.'
  : 'Inspect the execution; treat as manual until understood.';
const text = ['🚨 n8n failure (' + classification + ')', 'Workflow: ' + redact(wf.name) + ' | Execution: ' + redact(ex.id) + ' | Node: ' + redact(ex.lastNodeExecuted),
  'Time: ' + new Date().toISOString(), 'Error: ' + msg, ref ? 'Order: ' + ref : '', 'Policy: ' + policy].filter(Boolean).join('\n').slice(0, 1500);
return [{ json: { workflow_name: redact(wf.name).slice(0, 100), execution_id: redact(ex.id).slice(0, 40), node_name: redact(ex.lastNodeExecuted).slice(0, 100), classification, message: msg, order_ref: ref,
  has_url: !!String($env.ALERT_WEBHOOK_URL || ''), payload: { text, content: text } } }];
