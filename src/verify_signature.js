// Workflow B - Verify X-Hub-Signature-256 over the EXACT raw request body (Webhook option "Raw Body" = on).
// Fails closed: if crypto is not allowed, the secret is missing, or the raw body is unavailable, the request is rejected.
const item = $input.first();
const headers = (item.json && item.json.headers) || {};
const sigHeader = String(headers['x-hub-signature-256'] || '');
const MAX_BYTES = 262144;
let reason = null, payload = null;
try {
  const crypto = require('crypto');
  const secret = String($env.META_APP_SECRET || '');
  if (secret.length < 16) throw new Error('META_APP_SECRET not configured');
  const keys = Object.keys(item.binary || {});
  if (!keys.length) throw new Error('raw body not available (enable Raw Body on the Webhook node)');
  const buf = await this.helpers.getBinaryDataBuffer(0, keys[0]);
  if (buf.length > MAX_BYTES) {
    reason = 'too_large';
  } else {
    const expected = 'sha256=' + crypto.createHmac('sha256', secret).update(buf).digest('hex');
    const a = Buffer.from(sigHeader, 'utf8'), b = Buffer.from(expected, 'utf8');
    if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) reason = 'bad_signature';
    else payload = JSON.parse(buf.toString('utf8'));   // we process the same bytes we verified
  }
} catch (e) {
  reason = 'verify_error: ' + String(e && e.message ? e.message : e).slice(0, 100);
}
return [{ json: { valid: reason === null, reason, payload } }];
