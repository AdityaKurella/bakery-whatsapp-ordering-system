// Workflow D - turn claimed outbox rows into Cloud API request bodies. The recipient always comes from the database row.
const S = ($('Load Settings').first().json || {}).settings || {};
//@@LIB@@
const ver = String($env.WHATSAPP_API_VERSION || ''), pnid = String($env.META_PHONE_NUMBER_ID || '');
const configOk = /^v\d{1,2}\.\d{1,2}$/.test(ver) && /^\d{5,25}$/.test(pnid);
const url = configOk ? 'https://graph.facebook.com/' + ver + '/' + pnid + '/messages' : '';
const one = (s, n) => plain(s, n).replace(/\s{2,}/g, ' ');
function orderItems(o) {
  return (o.items || []).map(i => '• ' + i.quantity + ' × ' + one(i.name, 60) + ' (' + one(i.variant, 20) + ')' + optsText(i.options)).join('\n');
}
function orderHead(o) { return (o.fulfillment_method === 'DELIVERY' ? 'Delivery' : 'Pickup') + ': ' + o.requested_local; }
function build(row) {
  const o = row.order || {};
  switch (row.kind) {
    case 'ORDER_CONFIRMED_CUSTOMER':
      return '✅ *Order confirmed!*\nReference: *' + o.order_ref + '*\n\n' + orderItems(o) + '\n\n' + orderHead(o) + (o.fulfillment_method === 'DELIVERY' ? '\nAddress: ' + one(o.delivery_address, 200) : '') +
        '\nTotal: *' + fmt(o.total_minor) + '*\nPayment: ' + (PAY_LABEL[o.payment_status] || o.payment_status) + '. ' + (S.payment_instructions || '') + '\n\nSay “status” to check your order, or “cancel my order” if you change your mind (subject to our cancellation rules).';
    case 'ORDER_NEW_BAKERY':
      return '🧾 *New order ' + o.order_ref + '*\nCustomer: ' + one(o.contact_name, 60) + ' (+' + o.contact_wa_id + ')\n\n' + orderItems(o) + '\n\n' + orderHead(o) + (o.fulfillment_method === 'DELIVERY' ? '\nAddress: ' + one(o.delivery_address, 200) : '') +
        '\nTotal: ' + fmt(o.total_minor) + ' · ' + (PAY_LABEL[o.payment_status] || o.payment_status);
    case 'ORDER_CANCELLED_BAKERY':
      return '❌ *Order cancelled by customer:* ' + o.order_ref + '\n' + one(o.contact_name, 60) + ' (+' + o.contact_wa_id + ')\n' + orderHead(o) + '\nTotal: ' + fmt(o.total_minor);
    case 'ORDER_STATUS_CUSTOMER': {
      const st = (row.payload || {}).status, note = (row.payload || {}).note;
      const msg = { PREPARING: 'We have started preparing it 🧁', READY: 'It is ready for ' + (o.fulfillment_method === 'DELIVERY' ? 'dispatch' : 'pickup') + ' 🎉', OUT_FOR_DELIVERY: 'It is out for delivery 🚚', COMPLETED: 'It is complete. Thank you! 💛', CANCELLED: 'It has been cancelled.' }[st] || 'Its status is now ' + (STATUS_LABEL[st] || st) + '.';
      return 'Update on order *' + o.order_ref + '*: ' + msg + (note ? '\n' + one(note, 200) : '');
    }
  }
  return '';
}
function tpl(t, row, text) {
  if (!t || !t.name || t.name === 'REPLACE_WITH_TEMPLATE_NAME') return null;
  const o = row.order || {};
  const vals = { order_ref: o.order_ref || '', summary: one((o.items || []).map(i => i.quantity + ' x ' + i.name).join(', '), 400), total: o.total_minor !== undefined ? fmt(o.total_minor) : '' };
  const params = (Array.isArray(t.params) ? t.params : []).map(k => ({ type: 'text', text: one(vals[k] || '-', 500) }));
  const template = { name: String(t.name), language: { code: String(t.language || 'en_US') } };
  if (params.length) template.components = [{ type: 'body', parameters: params }];
  return { type: 'template', template };
}
const out = [];
for (const it of $input.all()) {
  const row = it.json.item;
  const base = { id: row.id, send: false, outcome: null, code: null, text: null, provider_id: null, url, body: null };
  if (!configOk) { out.push({ json: Object.assign(base, { outcome: 'PERMANENT', code: 'CONFIG', text: 'WHATSAPP_API_VERSION or META_PHONE_NUMBER_ID missing/invalid' }) }); continue; }
  let msg = null;
  if (row.kind === 'REPLY') {
    const p = row.payload || {};
    if (row.window_open && p.message) msg = (row.last_error_code === 'INTERACTIVE_REJECTED' && p.fallback_text) ? { type: 'text', text: { body: clip(p.fallback_text, 4000), preview_url: false } } : p.message;
  } else {
    const text = build(row);
    if (!text) { out.push({ json: Object.assign(base, { outcome: 'PERMANENT', code: 'NO_TEMPLATE', text: 'unknown notification kind or missing order' }) }); continue; }
    if (row.window_open) msg = { type: 'text', text: { body: clip(text, 4000), preview_url: false } };
    else msg = tpl(row.recipient_type === 'BAKERY' ? S.bakery_notify_template : S.customer_status_template, row, text);
  }
  if (!msg) { out.push({ json: Object.assign(base, { outcome: 'BLOCKED_WINDOW', code: '131047', text: 'outside 24h window and no approved template configured' }) }); continue; }
  out.push({ json: Object.assign(base, { send: true, body: Object.assign({ messaging_product: 'whatsapp', recipient_type: 'individual', to: row.recipient_wa_id }, msg) }) });
}
return out;
