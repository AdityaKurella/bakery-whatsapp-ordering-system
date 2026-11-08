// Workflow C - Validate AI output. The model is advisory: every field is re-validated here and again by the database.
// Any failure (outage, 429, timeout, malformed JSON, disallowed action) falls back to the deterministic result.
const prev = $('Parse Intent').first().json;
const r = $input.first().json || {};
let intent = prev.intent || { action: 'UNKNOWN' };
let ai_used = false, ai_error = null;
try {
  if (r.error || !Array.isArray(r.content)) throw new Error('no_ai_output');
  let t = r.content.filter(b => b && b.type === 'text').map(b => String(b.text || '')).join('').trim();
  t = t.replace(/^```(?:json)?\s*/i, '').replace(/\s*```$/, '').trim();
  if (!t || t.length > 2000) throw new Error('bad_length');
  const o = JSON.parse(t);
  if (!o || typeof o !== 'object' || Array.isArray(o)) throw new Error('not_object');
  const ALLOWED = ['ADD', 'REMOVE', 'CHANGE', 'MENU', 'SHOW_CART', 'CHECKOUT', 'ORDER_STATUS', 'HELP', 'GREET'];
  const action = String(o.action || '').toUpperCase();
  if (!ALLOWED.includes(action)) throw new Error('action_not_allowed');
  const txt = (v, n, re) => (typeof v === 'string' ? v.replace(re, ' ').replace(/\s+/g, ' ').trim().slice(0, n) : '');
  const out = { action };
  const ref = txt(o.product_ref, 60, /[^\p{L}\p{N} '&-]/gu); if (ref) out.product_ref = ref;
  if (typeof o.quantity === 'number' && Number.isFinite(o.quantity) && Math.abs(o.quantity) <= 1000) out.quantity = o.quantity;
  const v = txt(o.variant, 20, /[^0-9A-Za-z .]/g); if (v) out.variant = v;
  if (['CAKES', 'PASTRIES', 'COOKIES', 'BREAD', 'CUSTOM_CAKES'].includes(o.category)) out.category = o.category;
  if (Number.isInteger(o.line_no) && o.line_no >= 1 && o.line_no <= 100) out.line_no = o.line_no;
  if (o.options && typeof o.options === 'object') {
    const op = {};
    for (const k of ['flavor', 'egg', 'frosting']) { const x = txt(o.options[k], 30, /[^\p{L} -]/gu); if (x) op[k] = x; }
    const mg = txt(o.options.message, 60, /[^\p{L}\p{N} .,!&'’-]/gu); if (mg) op.message = mg;
    if (Object.keys(op).length) out.options = op;
  }
  intent = out; ai_used = true;
} catch (e) { ai_error = String(e && e.message ? e.message : e).slice(0, 60); }
return [{ json: { intent, ai_used, ai_error } }];
