// Workflow A - Check verification request. Fails closed: any error => 403 (Meta then shows the subscription as failed).
const q = $input.first().json.query || {};
const pick = (k) => (q['hub.' + k] !== undefined ? q['hub.' + k] : (q.hub && typeof q.hub === 'object' ? q.hub[k] : undefined));
const mode = String(pick('mode') === undefined ? '' : pick('mode'));
const token = String(pick('verify_token') === undefined ? '' : pick('verify_token'));
const challenge = String(pick('challenge') === undefined ? '' : pick('challenge'));
const expected = String($env.META_VERIFY_TOKEN || '');
function safeEqual(a, b) {
  if (!b || a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
const ok = mode === 'subscribe' && expected.length >= 16 && safeEqual(token, expected) && /^[A-Za-z0-9_-]{1,100}$/.test(challenge);
// nothing from the request is logged or echoed except the validated challenge
return [{ json: { ok, challenge: ok ? challenge : '' } }];
