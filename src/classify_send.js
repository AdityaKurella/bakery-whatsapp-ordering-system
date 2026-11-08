// Workflow D - classify the WhatsApp Cloud API response. Retry only what is safe to retry.
const sent = $('Can Send?').all(0);          // items that went into the HTTP node, same order
const mask = (s) => String(s == null ? '' : s).replace(/\d{7,}/g, '[n]').replace(/Bearer\s+\S+/gi, 'Bearer [x]').slice(0, 250);
const out = [];
$input.all().forEach((it, i) => {
  const src = sent[(it.pairedItem && it.pairedItem.item !== undefined) ? it.pairedItem.item : i];
  const id = src && src.json ? src.json.id : null;
  const j = it.json || {};
  const status = Number(j.statusCode);
  const body = j.body && typeof j.body === 'object' ? j.body : {};
  const err = body.error || {};
  const code = String(err.code !== undefined ? err.code : '');
  let outcome, ec = code || String(status || ''), text = mask(err.message || (j.error && (j.error.message || j.error)) || '');
  let pid = null;
  if (!status) { outcome = 'RETRY'; ec = 'NETWORK'; text = mask(j.error && (j.error.message || j.error.description) || 'no response (timeout/network)'); }
  else if (status >= 200 && status < 300) {
    pid = body.messages && body.messages[0] && body.messages[0].id;
    if (pid) outcome = 'SENT'; else { outcome = 'PERMANENT'; ec = 'BAD_PROVIDER_RESPONSE'; text = 'success status without message id'; }
  }
  else if (status === 401 || code === '190') { outcome = 'AUTH'; ec = 'AUTH'; }
  else if (code === '131047' || code === '131051') { outcome = 'BLOCKED_WINDOW'; }
  else if (status === 429 || status === 408 || status >= 500 || ['130429', '131056', '80007', '131000', '133016'].includes(code)) { outcome = 'RETRY'; }
  else if (status === 400 && (code === '100' || code === '131009') && src && src.json.body && src.json.body.type === 'interactive') { outcome = 'RETRY'; ec = 'INTERACTIVE_REJECTED'; }
  else { outcome = 'PERMANENT'; }
  out.push({ json: { id, outcome, code: ec, text, provider_id: pid || null } });
});
return out;
