// Workflow E - one item per inbound event that needs replay (stale PENDING/PROCESSING, attempts below the limit).
const r = ($input.first().json || {}).r || {};
return (Array.isArray(r.replay_event_ids) ? r.replay_event_ids : []).filter(n => Number.isInteger(n)).map(n => ({ json: { event_id: n } }));
