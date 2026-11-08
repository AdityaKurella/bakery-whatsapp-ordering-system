-- sql_smoke_test.sql | Exercises the conversation engine WITHOUT WhatsApp or n8n. Everything is rolled back at the end.
-- Run on a scratch database after migrations 001-004:   psql -v ON_ERROR_STOP=1 -d bakery -f tests/sql_smoke_test.sql
-- Any failed expectation raises an exception with the step name. NOT executed by the author (no PostgreSQL available when written).
BEGIN;
UPDATE bakery.bakery_settings SET value = '{"1":["00:00","23:59"],"2":["00:00","23:59"],"3":["00:00","23:59"],"4":["00:00","23:59"],"5":["00:00","23:59"],"6":["00:00","23:59"],"7":["00:00","23:59"]}' WHERE key = 'opening_hours';
UPDATE bakery.bakery_settings SET value = '1' WHERE key = 'min_lead_minutes';
UPDATE bakery.bakery_settings SET value = '100000' WHERE key = 'rate_limit_per_minute';
UPDATE bakery.bakery_settings SET value = '"919800000099"' WHERE key = 'bakery_notify_wa_id';

CREATE FUNCTION pg_temp.say(p_wa text, p_msg text, p_text text, p_intent jsonb) RETURNS jsonb LANGUAGE plpgsql AS $f$
DECLARE v_ev bigint;
BEGIN
  INSERT INTO bakery.webhook_event_log(event_key, kind, wa_id, msg_type, event_ts, payload)
  VALUES (p_msg, 'MESSAGE', p_wa, 'text', now(), jsonb_build_object('name', 'Tester', 'type', 'text', 'text', p_text))
  ON CONFLICT (event_key) DO UPDATE SET event_key = excluded.event_key RETURNING id INTO v_ev;
  RETURN bakery.fn_handle_inbound(v_ev, p_intent);
END $f$;
CREATE FUNCTION pg_temp.expect(p_ok boolean, p_step text, p_got jsonb DEFAULT NULL) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN IF NOT coalesce(p_ok, false) THEN RAISE EXCEPTION 'SMOKE TEST FAILED at: % (got %)', p_step, p_got; END IF; END $f$;

DO $t$
DECLARE r jsonb; a text := '919800000001'; b text := '919800000002'; v_ref text; v_ver int; v_cnt int; v_when text := to_char((now() + interval '3 days') AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
BEGIN
  r := pg_temp.say(a, 'm01', 'hi', '{"action":"GREET"}');                    PERFORM pg_temp.expect(r->>'code' = 'WELCOME', 'greet', r);
  r := pg_temp.say(a, 'm02', 'cake', '{"action":"ADD","product_ref":"cake"}'); PERFORM pg_temp.expect(r->>'code' = 'CLARIFY_PRODUCT', 'ambiguous product asks to clarify', r);
  r := pg_temp.say(a, 'm03', 'x', '{"action":"ADD","product_ref":"zzz unknown thing"}'); PERFORM pg_temp.expect(r->>'code' = 'PRODUCT_NOT_FOUND', 'unknown product', r);
  r := pg_temp.say(a, 'm04', 'x', '{"action":"ADD","product_ref":"BRD-SEAS-01"}'); PERFORM pg_temp.expect(r->>'code' = 'UNAVAILABLE', 'inactive product', r);
  r := pg_temp.say(a, 'm05', 'x', '{"action":"ADD","product_ref":"chocolate pastry","quantity":-2}'); PERFORM pg_temp.expect(r->>'code' = 'INVALID_QUANTITY', 'negative qty', r);
  r := pg_temp.say(a, 'm06', 'x', '{"action":"ADD","product_ref":"chocolate pastry","quantity":0}'); PERFORM pg_temp.expect(r->>'code' = 'INVALID_QUANTITY', 'zero qty', r);
  r := pg_temp.say(a, 'm07', 'x', '{"action":"ADD","product_ref":"chocolate pastry","quantity":1.5}'); PERFORM pg_temp.expect(r->>'code' = 'INVALID_QUANTITY', 'fractional qty', r);
  r := pg_temp.say(a, 'm08', 'x', '{"action":"ADD","product_ref":"chocolate pastry","quantity":5000}'); PERFORM pg_temp.expect(r->>'code' = 'INVALID_QUANTITY', 'huge qty', r);
  r := pg_temp.say(a, 'm09', 'x', '{"action":"ADD","product_ref":"chocolate pastry","quantity":2}');
  PERFORM pg_temp.expect(r->>'code' = 'CART_UPDATED' AND (r->'cart'->>'subtotal_minor')::int = 18000, 'add 2 pastries at DB price', r);
  r := pg_temp.say(a, 'm10', 'x', '{"action":"ADD","product_ref":"chocolate truffle cake","price":1}');
  PERFORM pg_temp.expect(r->>'code' = 'ASK_OPTION' AND r->>'field' = 'variant' AND r->>'state' = 'COLLECTING_CUSTOMIZATION', 'cake asks for size; client-supplied price ignored', r);
  r := pg_temp.say(a, 'm11', '1 kg', '{"action":"SET_OPTION","variant":"1 kg"}');
  PERFORM pg_temp.expect(r->>'code' = 'CART_UPDATED' AND (r->'cart'->>'subtotal_minor')::int = 103000, 'size answer adds cake', r);
  r := pg_temp.say(a, 'm12', 'x', '{"action":"CHANGE","product_ref":"cake","variant":"2 kg"}');
  PERFORM pg_temp.expect((r->'cart'->>'subtotal_minor')::int = 178000, 'change cake to 2 kg', r);
  r := pg_temp.say(a, 'm13', 'x', '{"action":"REMOVE","product_ref":"pastry","quantity":1}');
  PERFORM pg_temp.expect((r->'cart'->>'subtotal_minor')::int = 169000, 'remove one pastry', r);
  -- custom cake: every required option is collected before it enters the cart
  r := pg_temp.say(a, 'm14', 'x', '{"action":"ADD","product_ref":"birthday cake"}');                  PERFORM pg_temp.expect(r->>'field' = 'variant', 'custom: variant', r);
  r := pg_temp.say(a, 'm15', 'x', '{"action":"SET_OPTION","variant":"1 kg"}');                         PERFORM pg_temp.expect(r->>'field' = 'flavor', 'custom: flavor', r);
  r := pg_temp.say(a, 'm16', 'x', '{"action":"SET_OPTION","options":{"flavor":"banana"}}');            PERFORM pg_temp.expect(r->>'field' = 'flavor' AND (r->>'invalid')::boolean, 'custom: invalid flavor re-asked', r);
  r := pg_temp.say(a, 'm17', 'x', '{"action":"SET_OPTION","options":{"flavor":"chocolate"}}');         PERFORM pg_temp.expect(r->>'field' = 'egg', 'custom: egg', r);
  r := pg_temp.say(a, 'm18', 'x', '{"action":"SET_OPTION","options":{"egg":"eggless"}}');              PERFORM pg_temp.expect(r->>'field' = 'frosting', 'custom: frosting', r);
  r := pg_temp.say(a, 'm19', 'x', '{"action":"SET_OPTION","options":{"frosting":"buttercream"}}');     PERFORM pg_temp.expect(r->>'field' = 'message', 'custom: message', r);
  r := pg_temp.say(a, 'm20', 'Happy Birthday Rahul', '{"action":"UNKNOWN"}');
  PERFORM pg_temp.expect(r->>'code' = 'CART_UPDATED' AND (r->'cart'->>'total_minor')::int = 279000, 'custom cake added using stored message text', r);
  -- checkout flow and time rules
  r := pg_temp.say(a, 'm21', 'x', '{"action":"CHECKOUT"}');                                            PERFORM pg_temp.expect(r->>'field' = 'fulfillment', 'checkout asks fulfilment', r);
  r := pg_temp.say(a, 'm22', 'x', '{"action":"DETAILS","method":"PICKUP"}');                           PERFORM pg_temp.expect(r->>'field' = 'time', 'then time', r);
  r := pg_temp.say(a, 'm23', 'x', '{"action":"DETAILS","requested_at":"2000-01-01T10:00:00Z"}');      PERFORM pg_temp.expect(r->'error'->>'code' = 'PAST', 'past time rejected', r);
  r := pg_temp.say(a, 'm24', 'x', json_build_object('action','DETAILS','requested_at', to_char((now() + interval '30 minutes') AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'))::jsonb);
  PERFORM pg_temp.expect(r->'error'->>'code' = 'TOO_SOON', 'custom cake lead time enforced', r);
  r := pg_temp.say(a, 'm25', 'x', json_build_object('action','DETAILS','requested_at', v_when)::jsonb);   PERFORM pg_temp.expect(r->>'field' = 'name', 'valid time then name', r);
  r := pg_temp.say(a, 'm26', 'Rahul Kumar', '{"action":"UNKNOWN"}');
  PERFORM pg_temp.expect(r->>'code' = 'REVIEW' AND r->>'state' = 'AWAITING_CONFIRMATION', 'summary shown before confirmation', r);
  v_ver := (r->'cart'->>'version')::int;
  -- explicit confirmation rules
  r := pg_temp.say(a, 'm27', 'x', '{"action":"CONFIRM","cart_version":"999"}');                        PERFORM pg_temp.expect(r->>'code' = 'REVIEW' AND (r->>'stale')::boolean, 'stale confirm button re-shows summary', r);
  SELECT count(*) INTO v_cnt FROM bakery.orders; PERFORM pg_temp.expect(v_cnt = 0, 'no order created by stale confirm');
  r := pg_temp.say(a, 'm28', 'x', json_build_object('action','CONFIRM','cart_version', v_ver::text)::jsonb);
  PERFORM pg_temp.expect(r->>'code' = 'ORDER_CONFIRMED', 'confirm creates order', r);
  v_ref := r->>'order_ref';
  r := pg_temp.say(a, 'm29', 'x', '{"action":"CONFIRM"}');                                             PERFORM pg_temp.expect(r->>'code' = 'ALREADY_CONFIRMED', 'second confirm is idempotent', r);
  r := pg_temp.say(a, 'm28', 'x', '{"action":"CONFIRM"}');                                             PERFORM pg_temp.expect((r->>'replayed')::boolean AND r->>'code' = 'ORDER_CONFIRMED', 'redelivered message replays stored result', r);
  SELECT count(*) INTO v_cnt FROM bakery.orders WHERE customer_id = (SELECT id FROM bakery.customers WHERE wa_id = a); PERFORM pg_temp.expect(v_cnt = 1, 'exactly one order');
  PERFORM pg_temp.expect((SELECT total_minor = 279000 AND subtotal_minor = 279000 AND payment_status = 'PAYMENT_PENDING' FROM bakery.orders WHERE order_ref = v_ref), 'order totals from DB prices, payment pending');
  PERFORM pg_temp.expect((SELECT count(*) FROM bakery.order_items WHERE order_id = (SELECT id FROM bakery.orders WHERE order_ref = v_ref)) = 3, 'items snapshotted');
  -- outbox: notifications exist only as rows committed with the order; sending is a separate step
  PERFORM pg_temp.expect((SELECT count(*) FROM bakery.notification_outbox WHERE order_id = (SELECT id FROM bakery.orders WHERE order_ref = v_ref) AND status = 'PENDING') = 2, 'customer + bakery notifications queued');
  PERFORM pg_temp.expect((SELECT count(*) FROM bakery.fn_outbox_claim(10)) = 2, 'claim returns both rows once');
  PERFORM pg_temp.expect((SELECT count(*) FROM bakery.fn_outbox_claim(10)) = 0, 'claimed rows are not claimed twice');
  r := bakery.fn_outbox_record((SELECT id FROM bakery.notification_outbox WHERE kind = 'ORDER_NEW_BAKERY'), 'RETRY', '131000', 'simulated 5xx', NULL);
  PERFORM pg_temp.expect(r->>'status' = 'PENDING', 'failed notification is retried, not duplicated', r);
  PERFORM pg_temp.expect((SELECT count(*) FROM bakery.orders) = 1, 'notification failure did not touch the order');
  r := bakery.fn_outbox_record((SELECT id FROM bakery.notification_outbox WHERE kind = 'ORDER_CONFIRMED_CUSTOMER'), 'SENT', NULL, NULL, 'wamid.SIM');
  PERFORM pg_temp.expect(r->>'status' = 'SENT', 'sent recorded', r);
  -- ownership
  r := pg_temp.say(b, 'n01', 'x', json_build_object('action','ORDER_STATUS','order_ref', v_ref)::jsonb);  PERFORM pg_temp.expect(r->>'code' = 'ORDER_NOT_FOUND', 'other customer cannot look up my order', r);
  r := pg_temp.say(b, 'n02', 'x', json_build_object('action','CANCEL_ORDER','order_ref', v_ref)::jsonb);  PERFORM pg_temp.expect(r->>'code' = 'ORDER_NOT_FOUND', 'other customer cannot cancel my order', r);
  r := pg_temp.say(a, 'm30', 'x', '{"action":"ORDER_STATUS"}');                                        PERFORM pg_temp.expect(r->>'code' = 'ORDER_STATUS', 'owner can look up', r);
  -- cancellation
  r := pg_temp.say(a, 'm31', 'x', json_build_object('action','CANCEL_ORDER','order_ref', v_ref)::jsonb);  PERFORM pg_temp.expect(r->>'code' = 'CANCEL_ORDER_CONFIRM', 'cancel asks for confirmation', r);
  r := pg_temp.say(a, 'm32', 'x', json_build_object('action','CANCEL_ORDER_YES','order_ref', v_ref)::jsonb); PERFORM pg_temp.expect(r->>'code' = 'ORDER_CANCELLED', 'cancel confirmed', r);
  r := bakery.fn_set_order_status(v_ref, 'PREPARING', 'staff', NULL);                                  PERFORM pg_temp.expect(r->>'code' = 'INVALID_TRANSITION', 'cannot reopen a cancelled order', r);
  -- staff flow on a fresh order is covered by the manual test matrix; transitions table is checked here
  r := bakery.fn_set_order_status('BK-000000-00000-ZZZ', 'PREPARING', 'staff', NULL);                  PERFORM pg_temp.expect(r->>'code' = 'NOT_FOUND', 'unknown order ref', r);
  -- abandoned cart expiry
  r := pg_temp.say(b, 'n03', 'x', '{"action":"ADD","product_ref":"chocolate pastry"}');                PERFORM pg_temp.expect(r->>'code' = 'CART_UPDATED', 'second customer has an independent cart', r);
  PERFORM pg_temp.expect((r->'cart'->>'item_count')::int = 1, 'no state leakage between customers', r);
  UPDATE bakery.carts SET expires_at = now() - interval '1 minute' WHERE status = 'OPEN';
  r := bakery.fn_maintenance();                                                                        PERFORM pg_temp.expect((r->>'expired_carts')::int >= 1, 'maintenance expires abandoned carts', r);
  r := pg_temp.say(b, 'n04', 'x', '{"action":"SHOW_CART"}');                                           PERFORM pg_temp.expect(r->>'code' = 'CART_EMPTY', 'expired cart is gone', r);
  -- event intake idempotency
  r := bakery.fn_enqueue_events('[{"kind":"MESSAGE","event_key":"wamid.DUP1","wa_id":"919800000003","msg_type":"text","event_ts":"1790000000","payload":{"text":"hi"}}]');
  PERFORM pg_temp.expect(jsonb_array_length(r->'new_event_ids') = 1, 'first delivery stored', r);
  r := bakery.fn_enqueue_events('[{"kind":"MESSAGE","event_key":"wamid.DUP1","wa_id":"919800000003","msg_type":"text","event_ts":"1790000000","payload":{"text":"hi"}}]');
  PERFORM pg_temp.expect(jsonb_array_length(r->'new_event_ids') = 0 AND (r->>'duplicates')::int = 1, 'duplicate delivery dropped', r);
  RAISE NOTICE 'SMOKE TEST PASSED';
END $t$;
ROLLBACK;
