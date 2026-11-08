// Workflow D - validate a staff status-update request (Header Auth already enforced by the Webhook node).
const b = ($input.first().json || {}).body || {};
const STATUS = ['PREPARING', 'READY', 'OUT_FOR_DELIVERY', 'COMPLETED', 'CANCELLED'];
const PAY = ['PAID', 'FAILED', 'REFUNDED', 'PAYMENT_PENDING'];
const ref = String(b.order_ref || '').trim().toUpperCase();
const status = String(b.status || '').trim().toUpperCase();
const pay = String(b.payment_status || '').trim().toUpperCase();
const actor = String(b.actor || 'staff').replace(/[^\w .@-]/g, '').slice(0, 60) || 'staff';
const note = String(b.note || '').replace(/[\u0000-\u001F\u007F]/g, ' ').slice(0, 200);
let error = null;
if (!/^BK-\d{6}-\d{5}-[A-Z0-9]{3}$/.test(ref)) error = 'invalid order_ref';
else if ((status && pay) || (!status && !pay)) error = 'send exactly one of status or payment_status';
else if (status && !STATUS.includes(status)) error = 'invalid status';
else if (pay && !PAY.includes(pay)) error = 'invalid payment_status';
return [{ json: { valid: !error, error, order_ref: ref, status, payment_status: pay, actor, note } }];
