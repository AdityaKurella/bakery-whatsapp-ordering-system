// Workflow B - one item per newly stored inbound message event (duplicates were already dropped by the database).
const r = ($('Enqueue Events').first().json || {}).r || {};
return (Array.isArray(r.new_event_ids) ? r.new_event_ids : []).filter(n => Number.isInteger(n)).map(n => ({ json: { event_id: n } }));
