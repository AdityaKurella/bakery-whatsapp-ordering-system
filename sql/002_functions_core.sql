-- 002_functions_core.sql | helpers, event intake, outbox, order status, maintenance
-- NOT executed against a live PostgreSQL by the author. Run on a scratch database first.
BEGIN;

CREATE FUNCTION bakery._try_numeric(p text) RETURNS numeric LANGUAGE plpgsql IMMUTABLE AS $fn$
DECLARE v numeric;
BEGIN
  v := p::numeric;
  IF v = 'NaN'::numeric THEN RETURN NULL; END IF;
  RETURN v;
EXCEPTION WHEN others THEN RETURN NULL;
END $fn$;

CREATE FUNCTION bakery._try_ts(p text) RETURNS timestamptz LANGUAGE plpgsql STABLE AS $fn$
BEGIN RETURN p::timestamptz; EXCEPTION WHEN others THEN RETURN NULL; END $fn$;

CREATE FUNCTION bakery._setting(p_key text) RETURNS jsonb LANGUAGE sql STABLE AS $fn$
  SELECT value FROM bakery.bakery_settings WHERE key = p_key
$fn$;

CREATE FUNCTION bakery._setting_text(p_key text, p_default text) RETURNS text LANGUAGE sql STABLE AS $fn$
  SELECT coalesce((SELECT value #>> '{}' FROM bakery.bakery_settings WHERE key = p_key), p_default)
$fn$;

CREATE FUNCTION bakery._setting_int(p_key text, p_default int) RETURNS int LANGUAGE sql STABLE AS $fn$
  SELECT coalesce((SELECT (value #>> '{}')::int FROM bakery.bakery_settings WHERE key = p_key AND jsonb_typeof(value) = 'number'), p_default)
$fn$;

-- all non-secret settings as one object (keys starting with "_" are internal)
CREATE FUNCTION bakery.fn_get_settings() RETURNS jsonb LANGUAGE sql STABLE AS $fn$
  SELECT coalesce(jsonb_object_agg(key, value), '{}'::jsonb) FROM bakery.bakery_settings WHERE key NOT LIKE '\_%'
$fn$;

CREATE FUNCTION bakery._status_rank(p text) RETURNS int LANGUAGE sql IMMUTABLE AS $fn$
  SELECT CASE p WHEN 'sent' THEN 1 WHEN 'delivered' THEN 2 WHEN 'read' THEN 3 WHEN 'failed' THEN 9 ELSE 0 END
$fn$;

-- ---------------------------------------------------------------- intake
-- p_events: array of {kind, event_key, wa_id, msg_type, event_ts(epoch s), payload{...minimal...}}
CREATE FUNCTION bakery.fn_enqueue_events(p_events jsonb) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  e jsonb; v_id bigint; v_new bigint[] := '{}'; v_dup int := 0; v_rej int := 0;
  v_wa text; v_ts timestamptz;
BEGIN
  IF p_events IS NULL OR jsonb_typeof(p_events) <> 'array' THEN
    RAISE EXCEPTION 'p_events must be a JSON array';
  END IF;
  FOR e IN SELECT x FROM jsonb_array_elements(p_events) AS x LOOP
    v_id := NULL;
    v_wa := e->>'wa_id';
    IF (e->>'kind') NOT IN ('MESSAGE','STATUS')
       OR coalesce(e->>'event_key','') = '' OR char_length(e->>'event_key') > 200
       OR (v_wa IS NOT NULL AND v_wa !~ '^[0-9]{6,20}$') THEN
      v_rej := v_rej + 1; CONTINUE;
    END IF;
    v_ts := to_timestamp(bakery._try_numeric(e->>'event_ts')::double precision);

    IF e->>'kind' = 'MESSAGE' THEN
      INSERT INTO bakery.webhook_event_log(event_key, kind, wa_id, msg_type, event_ts, payload)
      VALUES (e->>'event_key', 'MESSAGE', v_wa, left(e->>'msg_type', 30), v_ts, coalesce(e->'payload', '{}'::jsonb))
      ON CONFLICT (event_key) DO NOTHING
      RETURNING id INTO v_id;
      IF v_id IS NULL THEN v_dup := v_dup + 1; ELSE v_new := v_new || v_id; END IF;
    ELSE
      INSERT INTO bakery.webhook_event_log(event_key, kind, wa_id, msg_type, event_ts, payload, status, processed_at)
      VALUES (e->>'event_key', 'STATUS', v_wa, 'status', v_ts, coalesce(e->'payload', '{}'::jsonb), 'DONE', now())
      ON CONFLICT (event_key) DO NOTHING
      RETURNING id INTO v_id;
      IF v_id IS NULL THEN
        v_dup := v_dup + 1;
      ELSE
        -- delivery receipts only ever move an outbox row "forward" (sent < delivered < read; failed is final)
        UPDATE bakery.notification_outbox o
           SET delivery_status = e->'payload'->>'status',
               delivery_error  = left(e->'payload'->>'error', 300)
         WHERE o.provider_message_id = e->'payload'->>'message_id'
           AND bakery._status_rank(coalesce(o.delivery_status, '')) <= bakery._status_rank(e->'payload'->>'status');
      END IF;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('new_event_ids', to_jsonb(v_new), 'duplicates', v_dup, 'rejected', v_rej);
END $fn$;

-- atomically claim one message event (zero rows = already done / being processed elsewhere)
CREATE FUNCTION bakery.fn_claim_event(p_event_id bigint) RETURNS SETOF jsonb LANGUAGE plpgsql AS $fn$
BEGIN
  RETURN QUERY
  WITH u AS (
    UPDATE bakery.webhook_event_log
       SET status = 'PROCESSING', claimed_at = now(), attempts = attempts + 1
     WHERE id = p_event_id AND kind = 'MESSAGE'
       AND (status = 'PENDING' OR (status = 'PROCESSING' AND claimed_at < now() - interval '5 minutes'))
    RETURNING id, event_key, wa_id, msg_type, event_ts, payload, attempts)
  SELECT coalesce(u.payload, '{}'::jsonb) || jsonb_build_object(
           'event_id', u.id, 'event_key', u.event_key, 'wa_id', u.wa_id, 'msg_type', u.msg_type,
           'event_ts', extract(epoch FROM u.event_ts), 'attempts', u.attempts)
    FROM u;
END $fn$;

CREATE FUNCTION bakery.fn_session_hint(p_wa_id text) RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE r jsonb;
BEGIN
  SELECT jsonb_build_object('state', s.state, 'awaiting', s.context->>'awaiting', 'pending_cancel', s.context->>'pending_cancel', 'has_pending_line', s.context ? 'pending_line',
           'terms', (SELECT coalesce(jsonb_agg(DISTINCT w), '[]'::jsonb)
                       FROM (SELECT unnest(regexp_split_to_array(lower(name), '[^[:alnum:]]+')) AS w FROM bakery.products WHERE is_active) t
                      WHERE length(w) >= 4))
    INTO r
    FROM bakery.customers c JOIN bakery.customer_sessions s ON s.customer_id = c.id
   WHERE c.wa_id = p_wa_id;
  RETURN coalesce(r, jsonb_build_object('state', 'NEW', 'awaiting', NULL, 'terms',
    (SELECT coalesce(jsonb_agg(DISTINCT w), '[]'::jsonb)
       FROM (SELECT unnest(regexp_split_to_array(lower(name), '[^[:alnum:]]+')) AS w FROM bakery.products WHERE is_active) t WHERE length(w) >= 4)));
END $fn$;

-- p_messages: array of {message:{type:'text'|'interactive',...}, fallback_text:'...'} (max 5)
CREATE FUNCTION bakery.fn_enqueue_replies(p_event_id bigint, p_messages jsonb) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE ev bakery.webhook_event_log%ROWTYPE; v_cid bigint; v_ids bigint[];
BEGIN
  SELECT * INTO ev FROM bakery.webhook_event_log WHERE id = p_event_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'event % not found', p_event_id; END IF;
  SELECT id INTO v_cid FROM bakery.customers WHERE wa_id = ev.wa_id;   -- recipient comes from the DB, never from the caller
  IF p_messages IS NOT NULL AND jsonb_typeof(p_messages) = 'array' AND jsonb_array_length(p_messages) BETWEEN 1 AND 5 THEN
    WITH ins AS (
      INSERT INTO bakery.notification_outbox(dedupe_key, kind, recipient_type, recipient_wa_id, customer_id, payload)
      SELECT 'reply:' || ev.id || ':' || t.ord, 'REPLY', 'CUSTOMER', ev.wa_id, v_cid, t.m
        FROM jsonb_array_elements(p_messages) WITH ORDINALITY AS t(m, ord)
       WHERE t.m->'message'->>'type' IN ('text','interactive')
      ON CONFLICT (dedupe_key) DO NOTHING
      RETURNING id)
    SELECT array_agg(id) INTO v_ids FROM ins;
  END IF;
  UPDATE bakery.webhook_event_log SET status = 'DONE', processed_at = now(), last_error = NULL WHERE id = p_event_id;
  RETURN jsonb_build_object('outbox_ids', to_jsonb(coalesce(v_ids, '{}'::bigint[])));
END $fn$;

-- ---------------------------------------------------------------- order json
CREATE FUNCTION bakery._order_json(p_order_id bigint) RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE o bakery.orders%ROWTYPE; v_tz text := bakery._setting_text('timezone', 'UTC'); v_items jsonb;
BEGIN
  SELECT * INTO o FROM bakery.orders WHERE id = p_order_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object('name', i.product_name, 'variant', i.variant_label, 'quantity', i.quantity,
           'unit_price_minor', i.unit_price_minor, 'line_total_minor', i.line_total_minor, 'options', i.options) ORDER BY i.id), '[]'::jsonb)
    INTO v_items FROM bakery.order_items i WHERE i.order_id = o.id;
  RETURN jsonb_build_object(
    'order_ref', o.order_ref, 'status', o.status, 'payment_status', o.payment_status,
    'fulfillment_method', o.fulfillment_method, 'requested_at', o.requested_at,
    'requested_local', to_char(o.requested_at AT TIME ZONE v_tz, 'Dy DD Mon YYYY, HH12:MI AM'),
    'contact_name', o.contact_name, 'contact_wa_id', o.contact_wa_id, 'delivery_address', o.delivery_address, 'currency_code', o.currency_code,
    'subtotal_minor', o.subtotal_minor, 'discount_minor', o.discount_minor, 'delivery_fee_minor', o.delivery_fee_minor,
    'tax_minor', o.tax_minor, 'total_minor', o.total_minor, 'items', v_items, 'created_at', o.created_at);
END $fn$;

-- ---------------------------------------------------------------- outbox
CREATE FUNCTION bakery.fn_outbox_claim(p_limit int DEFAULT 10) RETURNS SETOF jsonb LANGUAGE plpgsql AS $fn$
BEGIN
  RETURN QUERY
  WITH picked AS (
    SELECT id FROM bakery.notification_outbox
     WHERE status = 'PENDING' AND next_attempt_at <= now()
     ORDER BY id LIMIT greatest(1, least(p_limit, 50))
     FOR UPDATE SKIP LOCKED),
  u AS (
    UPDATE bakery.notification_outbox o
       SET status = 'PROCESSING', locked_at = now(), attempts = o.attempts + 1
      FROM picked WHERE o.id = picked.id
    RETURNING o.id, o.kind, o.recipient_type, o.recipient_wa_id, o.payload, o.attempts, o.order_id, o.last_error_code)
  SELECT jsonb_build_object(
           'id', u.id, 'kind', u.kind, 'recipient_type', u.recipient_type, 'recipient_wa_id', u.recipient_wa_id,
           'payload', u.payload, 'attempts', u.attempts, 'last_error_code', u.last_error_code,
           'window_open', EXISTS (SELECT 1 FROM bakery.customers c
                                   WHERE c.wa_id = u.recipient_wa_id AND c.last_inbound_at > now() - interval '24 hours'),
           'order', CASE WHEN u.order_id IS NULL THEN NULL ELSE bakery._order_json(u.order_id) END)
    FROM u ORDER BY u.id;
END $fn$;

-- p_outcome: SENT | RETRY | BLOCKED_WINDOW | PERMANENT | AUTH
CREATE FUNCTION bakery.fn_outbox_record(p_id bigint, p_outcome text, p_error_code text, p_error text, p_provider_id text)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE o bakery.notification_outbox%ROWTYPE; v_max int := bakery._setting_int('outbox_max_attempts', 6); v_delay numeric;
BEGIN
  SELECT * INTO o FROM bakery.notification_outbox WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF o.status <> 'PROCESSING' THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_processing', 'status', o.status); END IF;

  IF p_outcome = 'SENT' THEN
    UPDATE bakery.notification_outbox
       SET status = 'SENT', provider_message_id = left(p_provider_id, 200), sent_at = now(), locked_at = NULL,
           last_error_code = NULL, last_error = NULL
     WHERE id = p_id;
    RETURN jsonb_build_object('ok', true, 'status', 'SENT');
  ELSIF p_outcome = 'RETRY' AND o.attempts < v_max THEN
    v_delay := CASE WHEN p_error_code = 'INTERACTIVE_REJECTED' THEN 0
                        ELSE least(3600, 30 * power(2, o.attempts - 1)) * (0.5 + random()) END;   -- exponential backoff with jitter
    UPDATE bakery.notification_outbox
       SET status = 'PENDING', locked_at = NULL, next_attempt_at = now() + (v_delay * interval '1 second'),
           last_error_code = left(p_error_code, 40), last_error = left(p_error, 300)
     WHERE id = p_id;
    RETURN jsonb_build_object('ok', true, 'status', 'PENDING', 'retry_in_seconds', round(v_delay));
  ELSIF p_outcome = 'BLOCKED_WINDOW' THEN
    UPDATE bakery.notification_outbox
       SET status = 'BLOCKED_WINDOW', locked_at = NULL, last_error_code = left(p_error_code, 40), last_error = left(p_error, 300)
     WHERE id = p_id;
    RETURN jsonb_build_object('ok', true, 'status', 'BLOCKED_WINDOW');
  ELSE
    -- PERMANENT, AUTH, or RETRY with attempts exhausted: dead-letter (never retried automatically)
    UPDATE bakery.notification_outbox
       SET status = 'DEAD', locked_at = NULL,
           last_error_code = left(CASE WHEN p_outcome = 'RETRY' THEN 'RETRY_EXHAUSTED' WHEN p_outcome = 'AUTH' THEN 'AUTH' ELSE p_error_code END, 40),
           last_error = left(p_error, 300)
     WHERE id = p_id;
    RETURN jsonb_build_object('ok', true, 'status', 'DEAD');
  END IF;
END $fn$;

-- manual recovery: replay one dead / blocked row (bakery recipients re-read the current setting)
CREATE FUNCTION bakery.fn_requeue_outbox(p_id bigint) RETURNS int LANGUAGE plpgsql AS $fn$
DECLARE n int; v_notify text := bakery._setting_text('bakery_notify_wa_id', '');
BEGIN
  UPDATE bakery.notification_outbox
     SET status = 'PENDING', attempts = 0, next_attempt_at = now(), locked_at = NULL,
         recipient_wa_id = CASE WHEN recipient_type = 'BAKERY' AND v_notify ~ '^[0-9]{6,20}$' THEN v_notify ELSE recipient_wa_id END
   WHERE id = p_id AND status IN ('DEAD','BLOCKED_WINDOW');
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $fn$;

CREATE FUNCTION bakery.fn_requeue_dead_outbox(p_error_code text) RETURNS int LANGUAGE plpgsql AS $fn$
DECLARE r record; n int := 0;
BEGIN
  FOR r IN SELECT id FROM bakery.notification_outbox
            WHERE status IN ('DEAD','BLOCKED_WINDOW') AND last_error_code = p_error_code ORDER BY id LIMIT 200 LOOP
    n := n + bakery.fn_requeue_outbox(r.id);
  END LOOP;
  RETURN n;
END $fn$;

CREATE FUNCTION bakery.fn_replay_dead_event(p_id bigint) RETURNS int LANGUAGE plpgsql AS $fn$
DECLARE n int;
BEGIN
  UPDATE bakery.webhook_event_log SET status = 'PENDING', attempts = 0, claimed_at = NULL
   WHERE id = p_id AND status = 'DEAD' AND kind = 'MESSAGE' AND payload_purged_at IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $fn$;

-- ---------------------------------------------------------------- order status (staff / system)
CREATE FUNCTION bakery._restore_stock(p_order_id bigint) RETURNS void LANGUAGE sql AS $fn$
  UPDATE bakery.products p SET stock_qty = p.stock_qty + s.q
    FROM (SELECT product_id, sum(quantity)::int AS q FROM bakery.order_items WHERE order_id = p_order_id AND product_id IS NOT NULL GROUP BY product_id) s
   WHERE p.id = s.product_id AND p.stock_mode = 'TRACKED'
$fn$;

CREATE FUNCTION bakery.fn_set_order_status(p_order_ref text, p_new text, p_actor text, p_note text)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE o bakery.orders%ROWTYPE; v_new text := upper(btrim(coalesce(p_new, ''))); v_hid bigint;
        v_actor text := left(coalesce(nullif(btrim(p_actor), ''), 'unknown'), 60);
BEGIN
  SELECT * INTO o FROM bakery.orders WHERE order_ref = upper(btrim(coalesce(p_order_ref, ''))) FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'code', 'NOT_FOUND'); END IF;
  IF (o.status, v_new) NOT IN (('CONFIRMED','PREPARING'),('CONFIRMED','CANCELLED'),('PREPARING','READY'),('PREPARING','CANCELLED'),
                               ('READY','OUT_FOR_DELIVERY'),('READY','COMPLETED'),('READY','CANCELLED'),
                               ('OUT_FOR_DELIVERY','COMPLETED'),('OUT_FOR_DELIVERY','CANCELLED'))
     OR (v_new = 'OUT_FOR_DELIVERY' AND o.fulfillment_method <> 'DELIVERY') THEN
    RETURN jsonb_build_object('ok', false, 'code', 'INVALID_TRANSITION', 'from', o.status, 'to', v_new);
  END IF;
  UPDATE bakery.orders SET status = v_new,
         cancelled_at = CASE WHEN v_new = 'CANCELLED' THEN now() ELSE cancelled_at END,
         cancel_reason = CASE WHEN v_new = 'CANCELLED' THEN left(coalesce(p_note, 'cancelled by ' || v_actor), 200) ELSE cancel_reason END
   WHERE id = o.id;
  INSERT INTO bakery.order_status_history(order_id, kind, from_status, to_status, changed_by, note)
  VALUES (o.id, 'STATUS', o.status, v_new, v_actor, left(p_note, 300)) RETURNING id INTO v_hid;
  IF v_new = 'CANCELLED' THEN PERFORM bakery._restore_stock(o.id); END IF;
  INSERT INTO bakery.notification_outbox(dedupe_key, kind, recipient_type, recipient_wa_id, customer_id, order_id, payload)
  VALUES ('order:' || o.id || ':status:' || v_hid, 'ORDER_STATUS_CUSTOMER', 'CUSTOMER', o.contact_wa_id, o.customer_id, o.id,
          jsonb_build_object('status', v_new, 'note', left(p_note, 200)))
  ON CONFLICT (dedupe_key) DO NOTHING;
  RETURN jsonb_build_object('ok', true, 'order_ref', o.order_ref, 'from', o.status, 'to', v_new);
END $fn$;

CREATE FUNCTION bakery.fn_set_payment_status(p_order_ref text, p_new text, p_actor text, p_note text)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE o bakery.orders%ROWTYPE; v_new text := upper(btrim(coalesce(p_new, '')));
        v_actor text := left(coalesce(nullif(btrim(p_actor), ''), 'unknown'), 60);
BEGIN
  SELECT * INTO o FROM bakery.orders WHERE order_ref = upper(btrim(coalesce(p_order_ref, ''))) FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'code', 'NOT_FOUND'); END IF;
  IF (o.payment_status, v_new) NOT IN (('PAYMENT_PENDING','PAID'),('PAYMENT_PENDING','FAILED'),('FAILED','PAID'),
                                       ('FAILED','PAYMENT_PENDING'),('PAID','REFUNDED')) THEN
    RETURN jsonb_build_object('ok', false, 'code', 'INVALID_TRANSITION', 'from', o.payment_status, 'to', v_new);
  END IF;
  UPDATE bakery.orders SET payment_status = v_new WHERE id = o.id;
  INSERT INTO bakery.order_status_history(order_id, kind, from_status, to_status, changed_by, note)
  VALUES (o.id, 'PAYMENT', o.payment_status, v_new, v_actor, left(p_note, 300));
  RETURN jsonb_build_object('ok', true, 'order_ref', o.order_ref, 'from', o.payment_status, 'to', v_new);
END $fn$;

-- ---------------------------------------------------------------- maintenance
CREATE FUNCTION bakery.fn_maintenance() RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_expired int := 0; v_requeued int := 0; v_dead_new int := 0; v_ids bigint[];
  v_max_ev int := bakery._setting_int('event_max_attempts', 5);
  v_ev_ret int := bakery._setting_int('event_retention_days', 14);
  v_pl_ret int := bakery._setting_int('payload_retention_days', 7);
  v_ob_ret int := bakery._setting_int('outbox_retention_days', 30);
  v_dead_ev int; v_dead_ob int; v_oldest numeric; v_auth int; v_fp text; v_last jsonb; v_alert boolean := false; v_text text;
BEGIN
  -- 1. abandoned carts
  WITH ex AS (UPDATE bakery.carts SET status = 'EXPIRED' WHERE status = 'OPEN' AND expires_at < now() RETURNING customer_id),
       s AS (UPDATE bakery.customer_sessions cs SET state = 'BROWSING', context = '{}'::jsonb
               FROM ex WHERE cs.customer_id = ex.customer_id
                AND cs.state IN ('BUILDING_CART','COLLECTING_CUSTOMIZATION','COLLECTING_CUSTOMER_DETAILS','REVIEWING_ORDER','AWAITING_CONFIRMATION')
             RETURNING 1)
  SELECT count(*) INTO v_expired FROM ex;

  -- 2. outbox rows stuck in PROCESSING (worker died). At-least-once: a send that succeeded but was never recorded can repeat.
  UPDATE bakery.notification_outbox SET status = 'PENDING', locked_at = NULL
   WHERE status = 'PROCESSING' AND locked_at < now() - interval '5 minutes';
  GET DIAGNOSTICS v_requeued = ROW_COUNT;

  -- 3. inbound events never finished: dead-letter after N attempts, otherwise hand back for replay
  UPDATE bakery.webhook_event_log SET status = 'DEAD', last_error = coalesce(last_error, 'max attempts exceeded')
   WHERE kind = 'MESSAGE' AND status IN ('PENDING','PROCESSING') AND attempts >= v_max_ev
     AND coalesce(claimed_at, received_at) < now() - interval '2 minutes';
  GET DIAGNOSTICS v_dead_new = ROW_COUNT;

  WITH st AS (UPDATE bakery.webhook_event_log SET status = 'PENDING'
               WHERE kind = 'MESSAGE' AND status IN ('PENDING','PROCESSING') AND attempts < v_max_ev
                 AND coalesce(claimed_at, received_at) < now() - interval '2 minutes'
              RETURNING id)
  SELECT coalesce(array_agg(id), '{}') INTO v_ids FROM (SELECT id FROM st ORDER BY id LIMIT 50) x;

  -- 4. retention (confirmed orders are never touched)
  UPDATE bakery.webhook_event_log SET payload = '{}'::jsonb, payload_purged_at = now()
   WHERE status = 'DONE' AND payload_purged_at IS NULL AND processed_at < now() - (v_pl_ret * interval '1 day');
  UPDATE bakery.processed_messages SET result = '{}'::jsonb
   WHERE processed_at < now() - (v_pl_ret * interval '1 day') AND result <> '{}'::jsonb;
  DELETE FROM bakery.webhook_event_log WHERE status IN ('DONE','IGNORED') AND coalesce(processed_at, received_at) < now() - (v_ev_ret * interval '1 day');
  -- idempotency keys are kept longer than the event log (Meta retries for up to ~7 days) so a late redelivery cannot be re-processed
  DELETE FROM bakery.processed_messages WHERE processed_at < now() - (greatest(30, v_ev_ret + 7) * interval '1 day');
  DELETE FROM bakery.notification_outbox WHERE status = 'SENT' AND sent_at < now() - (v_ob_ret * interval '1 day');
  DELETE FROM bakery.carts c WHERE c.status IN ('EXPIRED','CLEARED') AND c.updated_at < now() - interval '30 days'
     AND NOT EXISTS (SELECT 1 FROM bakery.orders o WHERE o.cart_id = c.id);
  DELETE FROM bakery.error_log WHERE occurred_at < now() - interval '30 days';

  -- 5. health numbers + de-duplicated alerting (same condition alerts at most once per hour)
  SELECT count(*) INTO v_dead_ev FROM bakery.webhook_event_log WHERE status = 'DEAD';
  SELECT count(*) INTO v_dead_ob FROM bakery.notification_outbox WHERE status IN ('DEAD','BLOCKED_WINDOW');
  SELECT coalesce(extract(epoch FROM now() - min(created_at)), 0) INTO v_oldest
    FROM bakery.notification_outbox WHERE status IN ('PENDING','PROCESSING');
  SELECT count(*) INTO v_auth FROM bakery.notification_outbox WHERE last_error_code = 'AUTH' AND updated_at > now() - interval '1 hour';

  IF v_dead_ev > 0 OR v_dead_ob > 0 OR v_oldest > 900 THEN
    v_fp := md5(v_dead_ev || '-' || v_dead_ob || '-' || (v_oldest > 900)::text || '-' || (v_auth > 0)::text);
    v_last := bakery._setting('_maintenance_last_alert');
    IF v_last IS NULL OR v_last->>'fp' <> v_fp OR (v_last->>'at')::timestamptz < now() - interval '1 hour' THEN
      v_alert := true;
      INSERT INTO bakery.bakery_settings(key, value, description)
      VALUES ('_maintenance_last_alert', jsonb_build_object('fp', v_fp, 'at', now()), 'internal alert de-duplication')
      ON CONFLICT (key) DO UPDATE SET value = excluded.value;
      v_text := format('Bakery system needs attention: dead events=%s, dead/blocked notifications=%s, oldest pending notification=%s s%s',
                       v_dead_ev, v_dead_ob, round(v_oldest),
                       CASE WHEN v_auth > 0 THEN ' (WhatsApp access token rejected: check META access token credential)' ELSE '' END);
    END IF;
  END IF;

  RETURN jsonb_build_object('expired_carts', v_expired, 'requeued_outbox', v_requeued, 'events_dead_lettered', v_dead_new,
    'replay_event_ids', to_jsonb(v_ids), 'dead_events', v_dead_ev, 'dead_outbox', v_dead_ob,
    'oldest_pending_seconds', round(v_oldest), 'alert', v_alert, 'alert_text', v_text);
END $fn$;

CREATE VIEW bakery.v_dead_letters AS
  SELECT 'EVENT'::text AS source, id, status, attempts, left(last_error, 200) AS error, received_at AS created_at
    FROM bakery.webhook_event_log WHERE status = 'DEAD'
  UNION ALL
  SELECT 'OUTBOX', id, status, attempts, left(coalesce(last_error_code, '') || ' ' || coalesce(last_error, ''), 200), created_at
    FROM bakery.notification_outbox WHERE status IN ('DEAD','BLOCKED_WINDOW');

-- GDPR/DPDP-style erasure helper. Orders are retained (accounting) but anonymised. REVIEW WITH YOUR LEGAL ADVISER.
CREATE FUNCTION bakery.fn_erase_customer(p_wa_id text) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE c bakery.customers%ROWTYPE; v_anon text;
BEGIN
  SELECT * INTO c FROM bakery.customers WHERE wa_id = p_wa_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'code', 'NOT_FOUND'); END IF;
  v_anon := lpad(c.id::text, 10, '0');
  DELETE FROM bakery.customer_sessions WHERE customer_id = c.id;
  DELETE FROM bakery.carts WHERE customer_id = c.id AND status <> 'CONFIRMED';
  UPDATE bakery.orders SET contact_name = 'ERASED', contact_wa_id = v_anon, delivery_address = CASE WHEN delivery_address IS NULL THEN NULL ELSE 'ERASED' END
   WHERE customer_id = c.id;
  UPDATE bakery.carts SET contact_name = NULL, delivery_address = NULL WHERE customer_id = c.id;
  UPDATE bakery.webhook_event_log SET payload = '{}'::jsonb, payload_purged_at = now() WHERE wa_id = c.wa_id;
  DELETE FROM bakery.notification_outbox WHERE recipient_wa_id = c.wa_id;
  UPDATE bakery.customers SET wa_id = v_anon, display_name = NULL, saved_name = NULL, erased_at = now() WHERE id = c.id;
  RETURN jsonb_build_object('ok', true);
END $fn$;

INSERT INTO bakery.schema_migrations(version) VALUES ('002_functions_core');
COMMIT;
