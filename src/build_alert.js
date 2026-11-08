// Workflows E/F - alert payload compatible with Slack ("text") and Discord ("content") incoming webhooks.
const r = ($input.first().json || {}).r || {};
const text = String(r.alert_text || 'Bakery system alert').slice(0, 1500);
return [{ json: { has_url: !!String($env.ALERT_WEBHOOK_URL || ''), payload: { text, content: text } } }];
