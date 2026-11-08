// Workflow B - turn a verified Meta payload into minimal normalized events. Status events never become orders.
const p = ($input.first().json || {}).payload || {};
const PNID = String($env.META_PHONE_NUMBER_ID || '');
const events = [];
const clean = (s, n) => String(s == null ? '' : s).replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g, '').slice(0, n);
const idOk = (s) => typeof s === 'string' && /^[A-Za-z0-9=_.\-]{8,200}$/.test(s);
const waOk = (s) => typeof s === 'string' && /^[0-9]{6,20}$/.test(s);
let ignored = 0;
if (p.object === 'whatsapp_business_account' && Array.isArray(p.entry)) {
  for (const entry of p.entry) {
    for (const ch of (entry && Array.isArray(entry.changes) ? entry.changes : [])) {
      const v = ch && ch.value;
      if (!v || ch.field !== 'messages') { ignored++; continue; }
      if (PNID && String(v.metadata && v.metadata.phone_number_id) !== PNID) { ignored++; continue; }   // other numbers are ignored
      const names = {};
      for (const c of (Array.isArray(v.contacts) ? v.contacts : [])) if (c && waOk(c.wa_id)) names[c.wa_id] = clean(c.profile && c.profile.name, 100);
      for (const m of (Array.isArray(v.messages) ? v.messages : [])) {
        if (!m || !idOk(m.id) || !waOk(m.from)) { ignored++; continue; }
        const type = clean(m.type, 30) || 'unknown';
        const pl = { name: names[m.from] || '', type, text: '', interactive_id: '', interactive_title: '' };
        if (type === 'text' && m.text) pl.text = clean(m.text.body, 1000);
        else if (type === 'interactive' && m.interactive) {
          const r = m.interactive.button_reply || m.interactive.list_reply || {};
          pl.interactive_id = clean(r.id, 200); pl.interactive_title = clean(r.title, 100);
        } else if (type === 'button' && m.button) { pl.interactive_id = clean(m.button.payload, 200); pl.text = clean(m.button.text, 200); }
        events.push({ kind: 'MESSAGE', event_key: m.id, wa_id: m.from, msg_type: type, event_ts: String(m.timestamp || ''), payload: pl });
      }
      for (const s of (Array.isArray(v.statuses) ? v.statuses : [])) {
        if (!s || !idOk(s.id) || !waOk(s.recipient_id)) { ignored++; continue; }
        const st = clean(s.status, 20);
        const err = Array.isArray(s.errors) && s.errors[0] ? clean(s.errors[0].code, 20) + ':' + clean(s.errors[0].title, 120) : '';
        events.push({ kind: 'STATUS', event_key: s.id + ':' + st, wa_id: s.recipient_id, msg_type: 'status', event_ts: String(s.timestamp || ''), payload: { message_id: s.id, status: st, error: err } });
      }
    }
  }
}
return [{ json: { events, count: events.length, ignored } }];
