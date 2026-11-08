// ---- shared helpers (inlined by tools/build_workflows.py at //@@LIB@@) ----
const CUR = String(S.currency_symbol || S.currency_code || '');
function fmt(minor) {
  const n = Number(minor) || 0, a = Math.abs(n), whole = Math.floor(a / 100), frac = a % 100;
  return (n < 0 ? '-' : '') + CUR + String(whole).replace(/\B(?=(\d{3})+(?!\d))/g, ',') + (frac ? '.' + String(frac).padStart(2, '0') : '');
}
function clip(s, n) { s = String(s == null ? '' : s); return s.length > n ? s.slice(0, n - 1) + '…' : s; }
function plain(s, n) { return clip(String(s == null ? '' : s).replace(/[\u0000-\u001F\u007F]/g, ' ').replace(/\s+/g, ' ').trim(), n); }
const STATUS_LABEL = { CONFIRMED: 'Confirmed', PREPARING: 'Being prepared', READY: 'Ready', OUT_FOR_DELIVERY: 'Out for delivery', COMPLETED: 'Completed', CANCELLED: 'Cancelled' };
const PAY_LABEL = { PAYMENT_PENDING: 'payment pending', PAID: 'paid', FAILED: 'payment failed', REFUNDED: 'refunded' };
function optsText(o) {
  if (!o || typeof o !== 'object') return '';
  const parts = [o.flavor, o.egg, o.frosting].filter(Boolean);
  let t = parts.join(', ');
  if (o.message) t += (t ? '; ' : '') + 'message: “' + plain(o.message, 60) + '”';
  return t ? ' [' + t + ']' : '';
}
function leadText(m) {
  m = Number(m) || 0;
  if (m < 120) return m + ' minutes';
  if (m < 2880) return Math.ceil(m / 60) + ' hours';
  return Math.ceil(m / 1440) + ' days';
}
function hoursText() {
  const H = S.opening_hours || {}, names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'], groups = [];
  for (let i = 1; i <= 7; i++) {
    const h = H[String(i)], key = Array.isArray(h) ? h.join('-') : 'closed', last = groups[groups.length - 1];
    if (last && last.key === key) last.to = names[i - 1]; else groups.push({ key, from: names[i - 1], to: names[i - 1] });
  }
  return groups.map(g => (g.from === g.to ? g.from : g.from + '–' + g.to) + ' ' + g.key.replace('-', '–')).join(', ');
}
function lineText(l) {
  return l.line_no + '. ' + l.name + ' (' + l.variant + ') × ' + l.quantity + ' — ' + fmt(l.line_total_minor) + optsText(l.options);
}
function totalsText(c) {
  let t = 'Subtotal: ' + fmt(c.subtotal_minor);
  if (Number(c.delivery_fee_minor) > 0) t += '\nDelivery: ' + fmt(c.delivery_fee_minor);
  if (Number(c.tax_minor) > 0) t += '\nTax: ' + fmt(c.tax_minor);
  return t + '\n*Total: ' + fmt(c.total_minor) + '*';
}
function whenText(c) {
  const m = c.fulfillment_method === 'DELIVERY' ? 'Delivery' : 'Pickup';
  return m + ' — ' + (c.requested_local || 'time not set');
}
