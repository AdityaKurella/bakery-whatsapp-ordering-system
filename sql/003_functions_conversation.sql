-- 003_functions_conversation.sql | state machine, cart, checkout, order confirmation
-- NOT executed against a live PostgreSQL by the author. Run on a scratch database first and run the SQL smoke tests in the README.
-- Design: n8n parses the message into an *intent*; this file validates it against trusted data and mutates state transactionally.
-- Every function returns structured data (codes), never customer-facing text. Rendering happens in n8n (Workflow C).
BEGIN;

-- ---------------------------------------------------------------- text matching helpers
CREATE FUNCTION bakery._stem(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
  SELECT CASE WHEN p ~ 'ies$' AND length(p) > 4 THEN left(p, length(p) - 3)
              WHEN p ~ 's$' AND length(p) > 3 THEN left(p, length(p) - 1)
              ELSE p END
$fn$;

-- every meaningful token of p_ref (stemmed) must occur in p_hay
CREATE FUNCTION bakery._tokens_match(p_hay text, p_ref text) RETURNS boolean LANGUAGE sql IMMUTABLE AS $fn$
  SELECT length(regexp_replace(coalesce(p_ref, ''), '[^[:alnum:]]', '', 'g')) >= 2
     AND NOT EXISTS (
       SELECT 1 FROM regexp_split_to_table(lower(coalesce(p_ref, '')), '[^[:alnum:]]+') AS t
        WHERE length(t) >= 2 AND t NOT IN ('the','my','and','for','with','one','two','some','any','please','piece','pieces')
          AND position(bakery._stem(t) IN lower(coalesce(p_hay, ''))) = 0)
$fn$;

CREATE FUNCTION bakery._resolve_product(p_ref text, p_category text) RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE v_ref text := btrim(coalesce(p_ref, '')); v_id bigint; v_ids bigint[]; v_cat text := upper(nullif(btrim(coalesce(p_category, '')), ''));
BEGIN
  IF v_ref = '' THEN RETURN jsonb_build_object('status', 'NOT_FOUND'); END IF;
  SELECT id INTO v_id FROM bakery.products WHERE code = upper(v_ref) LIMIT 1;
  IF v_id IS NULL THEN SELECT id INTO v_id FROM bakery.products WHERE lower(name) = lower(v_ref) AND is_active LIMIT 1; END IF;
  IF v_id IS NOT NULL THEN
    IF (SELECT is_active FROM bakery.products WHERE id = v_id) THEN
      RETURN jsonb_build_object('status', 'OK', 'product_id', v_id);
    END IF;
    RETURN jsonb_build_object('status', 'UNAVAILABLE', 'name', (SELECT name FROM bakery.products WHERE id = v_id));
  END IF;
  SELECT array_agg(p.id ORDER BY p.sort_order, p.id) INTO v_ids
    FROM bakery.products p
   WHERE p.is_active AND (v_cat IS NULL OR p.category = v_cat)
     AND bakery._tokens_match(p.name || ' ' || p.code || ' ' || replace(p.category, '_', ' '), v_ref);
  IF v_ids IS NULL THEN
    SELECT id INTO v_id FROM bakery.products p WHERE NOT p.is_active AND bakery._tokens_match(p.name, v_ref) LIMIT 1;
    IF v_id IS NOT NULL THEN
      RETURN jsonb_build_object('status', 'UNAVAILABLE', 'name', (SELECT name FROM bakery.products WHERE id = v_id));
    END IF;
    RETURN jsonb_build_object('status', 'NOT_FOUND');
  END IF;
  IF array_length(v_ids, 1) = 1 THEN RETURN jsonb_build_object('status', 'OK', 'product_id', v_ids[1]); END IF;
  RETURN jsonb_build_object('status', 'AMBIGUOUS', 'matches',
    (SELECT jsonb_agg(jsonb_build_object('code', code, 'name', name) ORDER BY sort_order, id)
       FROM (SELECT * FROM bakery.products WHERE id = ANY (v_ids) ORDER BY sort_order, id LIMIT 5) m));
END $fn$;

CREATE FUNCTION bakery._resolve_variant(p_product_id bigint, p_label text) RETURNS bigint LANGUAGE sql STABLE AS $fn$
  SELECT id FROM bakery.product_variants
   WHERE product_id = p_product_id AND is_active
     AND regexp_replace(lower(label), '\s+', '', 'g') = regexp_replace(lower(coalesce(p_label, '')), '\s+', '', 'g')
   LIMIT 1
$fn$;

CREATE FUNCTION bakery._variants_json(p_product_id bigint) RETURNS jsonb LANGUAGE sql STABLE AS $fn$
  SELECT coalesce(jsonb_agg(jsonb_build_object('label', label, 'price_minor', price_minor) ORDER BY sort_order, id), '[]'::jsonb)
    FROM bakery.product_variants WHERE product_id = p_product_id AND is_active
$fn$;

CREATE FUNCTION bakery._choices(p_field text) RETURNS jsonb LANGUAGE sql STABLE AS $fn$
  SELECT coalesce(CASE p_field WHEN 'flavor' THEN bakery._setting('cake_flavors')
                               WHEN 'egg' THEN bakery._setting('egg_options')
                               WHEN 'frosting' THEN bakery._setting('cake_frostings') END, '[]'::jsonb)
$fn$;

-- validates option values against the configured vocabulary; returns {ok:true,options:{}} or {ok:false,field,...}
CREATE FUNCTION bakery._clean_options(p_opts jsonb) RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE v_out jsonb := '{}'::jsonb; v_f text; v_val text; v_canon text; v_max int := bakery._setting_int('cake_message_max_len', 40);
BEGIN
  IF p_opts IS NULL OR jsonb_typeof(p_opts) <> 'object' THEN
    RETURN jsonb_build_object('ok', true, 'options', v_out);
  END IF;
  FOREACH v_f IN ARRAY ARRAY['flavor','egg','frosting'] LOOP
    v_val := btrim(p_opts->>v_f);
    IF v_val IS NULL OR v_val = '' THEN CONTINUE; END IF;
    v_canon := NULL;
    SELECT x INTO v_canon FROM jsonb_array_elements_text(bakery._choices(v_f)) AS x WHERE lower(x) = lower(v_val) LIMIT 1;
    IF v_canon IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'field', v_f, 'choices', bakery._choices(v_f));
    END IF;
    v_out := v_out || jsonb_build_object(v_f, v_canon);
  END LOOP;
  IF p_opts->>'message' IS NOT NULL THEN
    v_val := btrim(p_opts->>'message');
    IF lower(v_val) IN ('skip','none','no') THEN
      v_out := v_out || jsonb_build_object('message', '');
    ELSIF char_length(v_val) < 1 OR char_length(v_val) > v_max OR v_val !~ '^[[:alnum:] .,!&''’-]+$' THEN
      RETURN jsonb_build_object('ok', false, 'field', 'message', 'max', v_max);
    ELSE
      v_out := v_out || jsonb_build_object('message', v_val);
    END IF;
  END IF;
  RETURN jsonb_build_object('ok', true, 'options', v_out);
END $fn$;

CREATE FUNCTION bakery._pending_next(p_pending jsonb) RETURNS text LANGUAGE plpgsql STABLE AS $fn$
DECLARE pr bakery.products%ROWTYPE; o jsonb := coalesce(p_pending->'options', '{}'::jsonb);
BEGIN
  SELECT * INTO pr FROM bakery.products WHERE id = (p_pending->>'product_id')::bigint;
  IF p_pending->>'variant_id' IS NULL THEN RETURN 'variant'; END IF;
  IF 'flavor'   = ANY (pr.required_options) AND NOT (o ? 'flavor')   THEN RETURN 'flavor'; END IF;
  IF 'egg'      = ANY (pr.required_options) AND NOT (o ? 'egg')      THEN RETURN 'egg'; END IF;
  IF 'frosting' = ANY (pr.required_options) AND NOT (o ? 'frosting') THEN RETURN 'frosting'; END IF;
  IF 'message'  = ANY (pr.required_options) AND NOT (o ? 'message')  THEN RETURN 'message'; END IF;
  RETURN NULL;
END $fn$;

-- ---------------------------------------------------------------- time rules
CREATE FUNCTION bakery._lead_minutes(p_cart_id bigint) RETURNS int LANGUAGE sql STABLE AS $fn$
  SELECT greatest(bakery._setting_int('min_lead_minutes', 60),
                  coalesce((SELECT max(p.lead_time_minutes) FROM bakery.cart_items ci JOIN bakery.products p ON p.id = ci.product_id
                             WHERE ci.cart_id = p_cart_id), 0))
$fn$;

-- NULL = acceptable, otherwise PAST | TOO_SOON | TOO_FAR | CLOSED
CREATE FUNCTION bakery._time_error(p_ts timestamptz, p_cart_id bigint) RETURNS text LANGUAGE plpgsql STABLE AS $fn$
DECLARE v_tz text := bakery._setting_text('timezone', 'UTC'); v_hours jsonb; v_local timestamp;
BEGIN
  IF p_ts IS NULL THEN RETURN 'MISSING'; END IF;
  IF p_ts <= now() THEN RETURN 'PAST'; END IF;
  IF p_ts < now() + (bakery._lead_minutes(p_cart_id) * interval '1 minute') THEN RETURN 'TOO_SOON'; END IF;
  IF p_ts > now() + (bakery._setting_int('max_advance_days', 30) * interval '1 day') THEN RETURN 'TOO_FAR'; END IF;
  v_local := p_ts AT TIME ZONE v_tz;
  v_hours := bakery._setting('opening_hours') -> (extract(isodow FROM v_local)::int)::text;
  IF v_hours IS NULL OR jsonb_typeof(v_hours) <> 'array' THEN RETURN 'CLOSED'; END IF;
  IF NOT (v_local::time BETWEEN (v_hours->>0)::time AND (v_hours->>1)::time) THEN RETURN 'CLOSED'; END IF;
  RETURN NULL;
END $fn$;

-- ---------------------------------------------------------------- cart helpers
CREATE FUNCTION bakery._cart_json(p_cart_id bigint) RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE c bakery.carts%ROWTYPE; v_lines jsonb; v_sub bigint; v_fee bigint := 0; v_tax bigint := 0;
        v_tz text := bakery._setting_text('timezone', 'UTC');
BEGIN
  SELECT * INTO c FROM bakery.carts WHERE id = p_cart_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object('line_no', ci.line_no, 'product_code', p.code, 'name', p.name,
            'variant', v.label, 'quantity', ci.quantity, 'unit_price_minor', v.price_minor,
            'line_total_minor', v.price_minor * ci.quantity, 'options', ci.options) ORDER BY ci.line_no), '[]'::jsonb),
         coalesce(sum(v.price_minor * ci.quantity), 0)
    INTO v_lines, v_sub
    FROM (SELECT x.*, row_number() OVER (ORDER BY x.id) AS line_no FROM bakery.cart_items x WHERE x.cart_id = p_cart_id) ci
    JOIN bakery.products p ON p.id = ci.product_id
    JOIN bakery.product_variants v ON v.id = ci.variant_id;
  IF c.fulfillment_method = 'DELIVERY' AND v_sub > 0 THEN v_fee := bakery._setting_int('delivery_fee_minor', 0); END IF;
  v_tax := (v_sub * bakery._setting_int('tax_rate_bps', 0) + 5000) / 10000;   -- integer arithmetic only
  RETURN jsonb_build_object(
    'cart_id', c.id, 'version', c.version, 'fulfillment_method', c.fulfillment_method, 'requested_at', c.requested_at,
    'requested_local', CASE WHEN c.requested_at IS NULL THEN NULL ELSE to_char(c.requested_at AT TIME ZONE v_tz, 'Dy DD Mon YYYY, HH12:MI AM') END,
    'contact_name', c.contact_name, 'delivery_address', c.delivery_address, 'lines', v_lines,
    'item_count', jsonb_array_length(v_lines), 'subtotal_minor', v_sub, 'discount_minor', 0,
    'delivery_fee_minor', v_fee, 'tax_minor', v_tax, 'total_minor', v_sub + v_fee + v_tax);
END $fn$;

CREATE FUNCTION bakery._get_or_create_cart(p_customer_id bigint) RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE v bigint;
BEGIN
  SELECT id INTO v FROM bakery.carts WHERE customer_id = p_customer_id AND status = 'OPEN' AND expires_at > now();
  IF v IS NULL THEN
    UPDATE bakery.carts SET status = 'EXPIRED' WHERE customer_id = p_customer_id AND status = 'OPEN';
    INSERT INTO bakery.carts(customer_id, expires_at)
    VALUES (p_customer_id, now() + (bakery._setting_int('cart_ttl_minutes', 120) * interval '1 minute'))
    RETURNING id INTO v;
  END IF;
  RETURN v;
END $fn$;

CREATE FUNCTION bakery._touch_cart(p_cart_id bigint) RETURNS void LANGUAGE sql AS $fn$
  UPDATE bakery.carts SET version = version + 1, expires_at = now() + (bakery._setting_int('cart_ttl_minutes', 120) * interval '1 minute')
   WHERE id = p_cart_id
$fn$;

CREATE FUNCTION bakery._add_line(p_cart_id bigint, p_product_id bigint, p_variant_id bigint, p_qty int, p_opts jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE pr bakery.products%ROWTYPE; v_opts jsonb := coalesce(p_opts, '{}'::jsonb); v_key text; v_existing int; v_other int;
BEGIN
  SELECT * INTO pr FROM bakery.products WHERE id = p_product_id;
  IF NOT FOUND OR NOT pr.is_active
     OR NOT EXISTS (SELECT 1 FROM bakery.product_variants WHERE id = p_variant_id AND product_id = p_product_id AND is_active) THEN
    RETURN jsonb_build_object('ok', false, 'code', 'UNAVAILABLE', 'name', pr.name);
  END IF;
  IF v_opts->>'message' = '' THEN v_opts := v_opts - 'message'; END IF;
  v_key := p_variant_id::text || ':' || md5(v_opts::text);
  SELECT quantity INTO v_existing FROM bakery.cart_items WHERE cart_id = p_cart_id AND line_key = v_key;
  IF coalesce(v_existing, 0) + p_qty > pr.max_qty_per_order THEN
    RETURN jsonb_build_object('ok', false, 'code', 'INVALID_QUANTITY', 'max', pr.max_qty_per_order, 'name', pr.name);
  END IF;
  IF pr.stock_mode = 'TRACKED' THEN
    SELECT coalesce(sum(quantity), 0) INTO v_other FROM bakery.cart_items WHERE cart_id = p_cart_id AND product_id = p_product_id;
    IF v_other + p_qty > pr.stock_qty THEN
      RETURN jsonb_build_object('ok', false, 'code', 'UNAVAILABLE', 'name', pr.name, 'available', pr.stock_qty);
    END IF;
  END IF;
  INSERT INTO bakery.cart_items(cart_id, product_id, variant_id, quantity, options, line_key)
  VALUES (p_cart_id, p_product_id, p_variant_id, p_qty, v_opts, v_key)
  ON CONFLICT (cart_id, line_key) DO UPDATE SET quantity = bakery.cart_items.quantity + excluded.quantity;
  PERFORM bakery._touch_cart(p_cart_id);
  RETURN jsonb_build_object('ok', true);
END $fn$;

-- ---------------------------------------------------------------- action helpers (return {result, state?, ctx?})
CREATE FUNCTION bakery._advance_pending(p_cust bigint, p_pending jsonb, p_ctx jsonb) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE pr bakery.products%ROWTYPE; v_next text; v_cart bigint; v_add jsonb; v_label text;
        v_invalid boolean := coalesce((p_pending->>'invalid')::boolean, false);
        v_pending jsonb := p_pending - 'invalid';
        v_ctx jsonb := coalesce(p_ctx, '{}'::jsonb) - 'awaiting' - 'pending_line' - 'summary_version';
BEGIN
  SELECT * INTO pr FROM bakery.products WHERE id = (v_pending->>'product_id')::bigint;
  v_next := bakery._pending_next(v_pending);
  IF v_next IS NOT NULL THEN
    RETURN jsonb_build_object(
      'result', jsonb_build_object('code', 'ASK_OPTION', 'field', v_next, 'product', pr.name, 'invalid', v_invalid,
                 'choices', CASE WHEN v_next = 'variant' THEN bakery._variants_json(pr.id) ELSE bakery._choices(v_next) END,
                 'message_max', bakery._setting_int('cake_message_max_len', 40)),
      'state', 'COLLECTING_CUSTOMIZATION',
      'ctx', v_ctx || jsonb_build_object('awaiting', v_next, 'pending_line', v_pending));
  END IF;
  v_cart := bakery._get_or_create_cart(p_cust);
  v_add := bakery._add_line(v_cart, pr.id, (v_pending->>'variant_id')::bigint, (v_pending->>'qty')::int, coalesce(v_pending->'options', '{}'::jsonb));
  IF NOT (v_add->>'ok')::boolean THEN
    RETURN jsonb_build_object('result', v_add - 'ok',
      'state', CASE WHEN EXISTS (SELECT 1 FROM bakery.cart_items WHERE cart_id = v_cart) THEN 'BUILDING_CART' ELSE 'BROWSING' END,
      'ctx', v_ctx);
  END IF;
  SELECT label INTO v_label FROM bakery.product_variants WHERE id = (v_pending->>'variant_id')::bigint;
  RETURN jsonb_build_object(
    'result', jsonb_build_object('code', 'CART_UPDATED',
              'change', jsonb_build_object('type', 'ADDED', 'name', pr.name, 'variant', v_label, 'quantity', (v_pending->>'qty')::int),
              'cart', bakery._cart_json(v_cart)),
    'state', 'BUILDING_CART', 'ctx', v_ctx);
END $fn$;

CREATE FUNCTION bakery._act_add(p_cust bigint, p_intent jsonb, p_ctx jsonb) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE v_raw text := nullif(p_intent->>'quantity', ''); v_qty numeric; v_res jsonb; pr bakery.products%ROWTYPE;
        v_vid bigint; v_oc jsonb; v_opts jsonb; v_pending jsonb; v_invalid boolean := false;
BEGIN
  IF v_raw IS NULL THEN v_qty := 1; ELSE v_qty := bakery._try_numeric(v_raw); END IF;
  IF v_qty IS NULL OR v_qty <> trunc(v_qty) OR v_qty < 1 OR v_qty > 1000 THEN
    RETURN jsonb_build_object('result', jsonb_build_object('code', 'INVALID_QUANTITY'));
  END IF;
  v_res := bakery._resolve_product(p_intent->>'product_ref', p_intent->>'category');
  IF v_res->>'status' = 'NOT_FOUND' AND nullif(p_intent->>'product_ref_alt', '') IS NOT NULL THEN
    v_res := bakery._resolve_product(p_intent->>'product_ref_alt', p_intent->>'category');   -- e.g. "chocolate birthday cake" -> "birthday cake"
  END IF;
  IF v_res->>'status' = 'AMBIGUOUS' THEN
    RETURN jsonb_build_object('result', jsonb_build_object('code', 'CLARIFY_PRODUCT', 'matches', v_res->'matches', 'quantity', v_qty::int));
  ELSIF v_res->>'status' = 'UNAVAILABLE' THEN
    RETURN jsonb_build_object('result', jsonb_build_object('code', 'UNAVAILABLE', 'name', v_res->>'name'));
  ELSIF v_res->>'status' <> 'OK' THEN
    RETURN jsonb_build_object('result', jsonb_build_object('code', 'PRODUCT_NOT_FOUND'));
  END IF;
  SELECT * INTO pr FROM bakery.products WHERE id = (v_res->>'product_id')::bigint;
  IF v_qty > pr.max_qty_per_order THEN
    RETURN jsonb_build_object('result', jsonb_build_object('code', 'INVALID_QUANTITY', 'max', pr.max_qty_per_order, 'name', pr.name));
  END IF;
  v_oc := bakery._clean_options(p_intent->'options');
  IF NOT (v_oc->>'ok')::boolean THEN
    RETURN jsonb_build_object('result', jsonb_build_object('code', 'INVALID_OPTION', 'field', v_oc->>'field',
             'choices', v_oc->'choices', 'max', v_oc->'max'));
  END IF;
  v_opts := v_oc->'options';
  IF pr.category NOT IN ('CAKES','CUSTOM_CAKES') THEN
    v_opts := '{}'::jsonb;
  ELSIF cardinality(pr.required_options) = 0 THEN
    v_opts := v_opts - 'flavor' - 'egg' - 'frosting';
  END IF;
  IF nullif(btrim(p_intent->>'variant'), '') IS NOT NULL THEN
    v_vid := bakery._resolve_variant(pr.id, p_intent->>'variant');
    IF v_vid IS NULL THEN v_invalid := true; END IF;
  END IF;
  IF v_vid IS NULL AND (SELECT count(*) FROM bakery.product_variants WHERE product_id = pr.id AND is_active) = 1 THEN
    SELECT id INTO v_vid FROM bakery.product_variants WHERE product_id = pr.id AND is_active;
    v_invalid := false;
  END IF;
  v_pending := jsonb_build_object('product_id', pr.id, 'variant_id', v_vid, 'qty', v_qty::int, 'options', v_opts, 'invalid', v_invalid);
  RETURN bakery._advance_pending(p_cust, v_pending, p_ctx);
END $fn$;

-- fills the option the customer was just asked for (SET_OPTION, or free TEXT while a customization is pending)
CREATE FUNCTION bakery._act_option(p_cust bigint, p_intent jsonb, p_ctx jsonb) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE v_pending jsonb := p_ctx->'pending_line'; v_field text := p_ctx->>'awaiting'; v_oc jsonb; v_opts jsonb; v_vid bigint;
        v_raw text := p_intent->>'raw_text'; v_bad boolean := false;
BEGIN
  v_opts := coalesce(v_pending->'options', '{}'::jsonb);
  IF jsonb_typeof(p_intent->'options') = 'object' AND p_intent->'options' <> '{}'::jsonb THEN
    v_oc := bakery._clean_options(p_intent->'options');
  ELSIF v_field IN ('flavor','egg','frosting','message') THEN
    v_oc := bakery._clean_options(jsonb_build_object(v_field, v_raw));
  END IF;
  IF v_oc IS NOT NULL THEN
    IF (v_oc->>'ok')::boolean THEN v_opts := v_opts || (v_oc->'options'); ELSE v_bad := true; END IF;
  END IF;
  v_pending := jsonb_set(v_pending, '{options}', v_opts);
  IF nullif(p_intent->>'variant', '') IS NOT NULL OR v_field = 'variant' THEN
    v_vid := bakery._resolve_variant((v_pending->>'product_id')::bigint, coalesce(nullif(p_intent->>'variant', ''), v_raw));
    IF v_vid IS NULL THEN v_bad := true; ELSE v_pending := jsonb_set(v_pending, '{variant_id}', to_jsonb(v_vid)); END IF;
  END IF;
  IF v_bad THEN v_pending := v_pending || jsonb_build_object('invalid', true); END IF;
  RETURN bakery._advance_pending(p_cust, v_pending, p_ctx);
END $fn$;

CREATE FUNCTION bakery._act_edit(p_cust bigint, p_intent jsonb, p_ctx jsonb, p_remove boolean) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE v_cart bigint; v_ln numeric := bakery._try_numeric(p_intent->>'line_no'); v_lineno int; v_ids bigint[]; v_lines jsonb;
        li bakery.cart_items%ROWTYPE; pr bakery.products%ROWTYPE; v_raw text := nullif(p_intent->>'quantity', ''); v_qty numeric;
        v_vid bigint; v_key text; v_other_id bigint; v_other_qty int; v_target int; v_others int; v_ref text := nullif(btrim(p_intent->>'product_ref'), '');
        v_changed text;
BEGIN
  SELECT id INTO v_cart FROM bakery.carts WHERE customer_id = p_cust AND status = 'OPEN' AND expires_at > now();
  IF v_cart IS NULL OR NOT EXISTS (SELECT 1 FROM bakery.cart_items WHERE cart_id = v_cart) THEN
    RETURN jsonb_build_object('result', jsonb_build_object('code', 'CART_EMPTY'));
  END IF;
  IF v_ln BETWEEN 1 AND 1000 THEN v_lineno := v_ln::int; END IF;
  SELECT array_agg(s.id ORDER BY s.id) INTO v_ids
    FROM (SELECT x.id, x.product_id, row_number() OVER (ORDER BY x.id) AS line_no FROM bakery.cart_items x WHERE x.cart_id = v_cart) s
    JOIN bakery.products p ON p.id = s.product_id
   WHERE (v_lineno IS NOT NULL AND s.line_no = v_lineno)
      OR (v_lineno IS NULL AND v_ref IS NOT NULL AND bakery._tokens_match(p.name || ' ' || p.code || ' ' || replace(p.category, '_', ' '), v_ref))
      OR (v_lineno IS NULL AND v_ref IS NULL);
  IF v_ids IS NULL THEN
    RETURN jsonb_build_object('result', jsonb_build_object('code', 'LINE_NOT_FOUND', 'cart', bakery._cart_json(v_cart)));
  ELSIF array_length(v_ids, 1) > 1 THEN
    RETURN jsonb_build_object('result', jsonb_build_object('code', 'CLARIFY_LINE', 'cart', bakery._cart_json(v_cart)));
  END IF;
  SELECT * INTO li FROM bakery.cart_items WHERE id = v_ids[1] FOR UPDATE;
  SELECT * INTO pr FROM bakery.products WHERE id = li.product_id;

  IF v_raw IS NOT NULL THEN
    v_qty := bakery._try_numeric(v_raw);
    IF v_qty IS NULL OR v_qty <> trunc(v_qty) OR v_qty < 0 OR v_qty > 1000 THEN
      RETURN jsonb_build_object('result', jsonb_build_object('code', 'INVALID_QUANTITY', 'max', pr.max_qty_per_order, 'name', pr.name));
    END IF;
  END IF;

  IF p_remove THEN
    IF v_qty IS NULL OR v_qty >= li.quantity THEN
      DELETE FROM bakery.cart_items WHERE id = li.id;
    ELSE
      UPDATE bakery.cart_items SET quantity = quantity - v_qty::int WHERE id = li.id;
    END IF;
    v_changed := 'REMOVED';
  ELSE
    IF nullif(p_intent->>'variant', '') IS NULL AND v_qty IS NULL THEN
      RETURN jsonb_build_object('result', jsonb_build_object('code', 'EDIT_WHAT', 'cart', bakery._cart_json(v_cart)));
    END IF;
    v_target := coalesce(v_qty::int, li.quantity);
    IF v_target > pr.max_qty_per_order THEN
      RETURN jsonb_build_object('result', jsonb_build_object('code', 'INVALID_QUANTITY', 'max', pr.max_qty_per_order, 'name', pr.name));
    END IF;
    IF v_target > 0 AND pr.stock_mode = 'TRACKED' THEN
      SELECT coalesce(sum(quantity), 0) INTO v_others FROM bakery.cart_items WHERE cart_id = v_cart AND product_id = pr.id AND id <> li.id;
      IF v_others + v_target > pr.stock_qty THEN
        RETURN jsonb_build_object('result', jsonb_build_object('code', 'UNAVAILABLE', 'name', pr.name, 'available', pr.stock_qty));
      END IF;
    END IF;
    IF v_target = 0 THEN
      DELETE FROM bakery.cart_items WHERE id = li.id;
    ELSE
      IF nullif(p_intent->>'variant', '') IS NOT NULL THEN
        v_vid := bakery._resolve_variant(li.product_id, p_intent->>'variant');
        IF v_vid IS NULL THEN
          RETURN jsonb_build_object('result', jsonb_build_object('code', 'VARIANT_NOT_FOUND', 'product', pr.name, 'choices', bakery._variants_json(pr.id)));
        END IF;
        v_key := v_vid::text || ':' || md5(li.options::text);
        SELECT id, quantity INTO v_other_id, v_other_qty FROM bakery.cart_items WHERE cart_id = v_cart AND line_key = v_key AND id <> li.id;
        IF v_other_id IS NOT NULL THEN
          IF v_other_qty + v_target > pr.max_qty_per_order THEN
            RETURN jsonb_build_object('result', jsonb_build_object('code', 'INVALID_QUANTITY', 'max', pr.max_qty_per_order, 'name', pr.name));
          END IF;
          UPDATE bakery.cart_items SET quantity = v_other_qty + v_target WHERE id = v_other_id;
          DELETE FROM bakery.cart_items WHERE id = li.id;
        ELSE
          UPDATE bakery.cart_items SET variant_id = v_vid, line_key = v_key, quantity = v_target WHERE id = li.id;
        END IF;
      ELSE
        UPDATE bakery.cart_items SET quantity = v_target WHERE id = li.id;
      END IF;
    END IF;
    v_changed := 'CHANGED';
  END IF;
  PERFORM bakery._touch_cart(v_cart);
  RETURN jsonb_build_object(
    'result', jsonb_build_object('code', 'CART_UPDATED', 'change', jsonb_build_object('type', v_changed, 'name', pr.name), 'cart', bakery._cart_json(v_cart)),
    'state', CASE WHEN EXISTS (SELECT 1 FROM bakery.cart_items WHERE cart_id = v_cart) THEN 'BUILDING_CART' ELSE 'BROWSING' END,
    'ctx', coalesce(p_ctx, '{}'::jsonb) - 'awaiting' - 'pending_line' - 'summary_version');
END $fn$;

-- {ok:true} or {ok:false,error:{field,code}}; applies fulfillment/time/name/address; later fields are skipped after the first error
CREATE FUNCTION bakery._apply_details(p_cart_id bigint, p_intent jsonb) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE v_method text := upper(btrim(coalesce(p_intent->>'method', ''))); v_ts timestamptz; v_name text; v_addr text;
        v_err jsonb; v_changed boolean := false; v_t text;
BEGIN
  IF v_method <> '' THEN
    IF v_method NOT IN ('PICKUP','DELIVERY')
       OR NOT coalesce((bakery._setting(lower(v_method) || '_enabled') #>> '{}')::boolean, true) THEN
      v_err := jsonb_build_object('field', 'method', 'code', 'METHOD_UNAVAILABLE');
    ELSE
      UPDATE bakery.carts SET fulfillment_method = v_method WHERE id = p_cart_id; v_changed := true;
    END IF;
  END IF;
  IF v_err IS NULL AND nullif(p_intent->>'requested_at', '') IS NOT NULL THEN
    v_ts := bakery._try_ts(p_intent->>'requested_at');
    IF v_ts IS NULL THEN
      v_err := jsonb_build_object('field', 'time', 'code', 'INVALID_FORMAT');
    ELSE
      v_t := bakery._time_error(v_ts, p_cart_id);
      IF v_t IS NOT NULL THEN v_err := jsonb_build_object('field', 'time', 'code', v_t);
      ELSE UPDATE bakery.carts SET requested_at = v_ts WHERE id = p_cart_id; v_changed := true; END IF;
    END IF;
  END IF;
  v_name := btrim(regexp_replace(coalesce(p_intent->>'name', ''), '\s+', ' ', 'g'));
  IF v_err IS NULL AND v_name <> '' THEN
    IF v_name !~ '^[[:alpha:]][[:alpha:] .''-]{1,59}$' THEN
      v_err := jsonb_build_object('field', 'name', 'code', 'INVALID_FORMAT');
    ELSE UPDATE bakery.carts SET contact_name = v_name WHERE id = p_cart_id; v_changed := true; END IF;
  END IF;
  v_addr := btrim(regexp_replace(coalesce(p_intent->>'address', ''), '[\r\n\t]+', ', ', 'g'));
  IF v_err IS NULL AND v_addr <> '' THEN
    IF char_length(v_addr) < 10 OR char_length(v_addr) > 300 THEN
      v_err := jsonb_build_object('field', 'address', 'code', 'INVALID_FORMAT');
    ELSE UPDATE bakery.carts SET delivery_address = v_addr WHERE id = p_cart_id; v_changed := true; END IF;
  END IF;
  IF v_changed THEN PERFORM bakery._touch_cart(p_cart_id); END IF;
  IF v_err IS NOT NULL THEN RETURN jsonb_build_object('ok', false, 'error', v_err); END IF;
  RETURN jsonb_build_object('ok', true, 'changed', v_changed);
END $fn$;

CREATE FUNCTION bakery._ask_detail(p_cart_id bigint, p_field text, p_error text) RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE v_methods jsonb := '[]'::jsonb;
BEGIN
  IF coalesce((bakery._setting('pickup_enabled') #>> '{}')::boolean, true) THEN v_methods := v_methods || '"PICKUP"'::jsonb; END IF;
  IF coalesce((bakery._setting('delivery_enabled') #>> '{}')::boolean, true) THEN v_methods := v_methods || '"DELIVERY"'::jsonb; END IF;
  RETURN jsonb_build_object('code', 'ASK_DETAIL', 'field', p_field, 'error', p_error, 'methods', v_methods,
                            'lead_minutes', bakery._lead_minutes(p_cart_id));
END $fn$;

CREATE FUNCTION bakery._progress_checkout(p_cust bigint, p_cart_id bigint, p_ctx jsonb) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE c bakery.carts%ROWTYPE; v_saved text; v_err text; v_cj jsonb;
        v_ctx jsonb := coalesce(p_ctx, '{}'::jsonb) - 'awaiting' - 'pending_line' - 'summary_version';
BEGIN
  SELECT * INTO c FROM bakery.carts WHERE id = p_cart_id FOR UPDATE;
  IF NOT EXISTS (SELECT 1 FROM bakery.cart_items WHERE cart_id = p_cart_id) THEN
    RETURN jsonb_build_object('result', jsonb_build_object('code', 'CART_EMPTY'), 'state', 'BROWSING', 'ctx', v_ctx);
  END IF;
  IF c.fulfillment_method IS NULL THEN
    RETURN jsonb_build_object('result', bakery._ask_detail(p_cart_id, 'fulfillment', NULL), 'state', 'COLLECTING_CUSTOMER_DETAILS',
                              'ctx', v_ctx || jsonb_build_object('awaiting', 'fulfillment'));
  END IF;
  IF c.requested_at IS NULL THEN
    RETURN jsonb_build_object('result', bakery._ask_detail(p_cart_id, 'time', NULL), 'state', 'COLLECTING_CUSTOMER_DETAILS',
                              'ctx', v_ctx || jsonb_build_object('awaiting', 'time'));
  END IF;
  IF c.contact_name IS NULL THEN
    SELECT saved_name INTO v_saved FROM bakery.customers WHERE id = p_cust;
    IF v_saved IS NOT NULL THEN
      UPDATE bakery.carts SET contact_name = v_saved WHERE id = p_cart_id; PERFORM bakery._touch_cart(p_cart_id);
      c.contact_name := v_saved;
    ELSE
      RETURN jsonb_build_object('result', bakery._ask_detail(p_cart_id, 'name', NULL), 'state', 'COLLECTING_CUSTOMER_DETAILS',
                                'ctx', v_ctx || jsonb_build_object('awaiting', 'name'));
    END IF;
  END IF;
  IF c.fulfillment_method = 'DELIVERY' AND c.delivery_address IS NULL THEN
    RETURN jsonb_build_object('result', bakery._ask_detail(p_cart_id, 'address', NULL), 'state', 'COLLECTING_CUSTOMER_DETAILS',
                              'ctx', v_ctx || jsonb_build_object('awaiting', 'address'));
  END IF;
  v_err := bakery._time_error(c.requested_at, p_cart_id);   -- cart contents may have changed the lead time
  IF v_err IS NOT NULL THEN
    UPDATE bakery.carts SET requested_at = NULL WHERE id = p_cart_id; PERFORM bakery._touch_cart(p_cart_id);
    RETURN jsonb_build_object('result', bakery._ask_detail(p_cart_id, 'time', v_err), 'state', 'COLLECTING_CUSTOMER_DETAILS',
                              'ctx', v_ctx || jsonb_build_object('awaiting', 'time'));
  END IF;
  v_cj := bakery._cart_json(p_cart_id);
  IF c.fulfillment_method = 'DELIVERY' AND (v_cj->>'subtotal_minor')::bigint < bakery._setting_int('min_delivery_order_minor', 0) THEN
    RETURN jsonb_build_object('result', jsonb_build_object('code', 'MIN_DELIVERY', 'min_minor', bakery._setting_int('min_delivery_order_minor', 0), 'cart', v_cj),
                              'state', 'COLLECTING_CUSTOMER_DETAILS', 'ctx', v_ctx || jsonb_build_object('awaiting', 'fulfillment'));
  END IF;
  RETURN jsonb_build_object('result', jsonb_build_object('code', 'REVIEW', 'cart', v_cj), 'state', 'AWAITING_CONFIRMATION',
                            'ctx', v_ctx || jsonb_build_object('summary_version', (v_cj->>'version')::int));
END $fn$;

CREATE FUNCTION bakery._act_details(p_cust bigint, p_intent jsonb, p_state text, p_ctx jsonb) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE v_cart bigint := bakery._get_or_create_cart(p_cust); v_det jsonb;
BEGIN
  v_det := bakery._apply_details(v_cart, p_intent);
  IF NOT (v_det->>'ok')::boolean THEN
    RETURN jsonb_build_object('result', jsonb_build_object('code', 'DETAIL_ERROR', 'error', v_det->'error',
             'lead_minutes', bakery._lead_minutes(v_cart), 'cart', bakery._cart_json(v_cart)));
  END IF;
  IF p_state IN ('COLLECTING_CUSTOMER_DETAILS','AWAITING_CONFIRMATION','REVIEWING_ORDER')
     AND EXISTS (SELECT 1 FROM bakery.cart_items WHERE cart_id = v_cart) THEN
    RETURN bakery._progress_checkout(p_cust, v_cart, p_ctx);
  END IF;
  RETURN jsonb_build_object('result', jsonb_build_object('code', 'DETAILS_SAVED', 'cart', bakery._cart_json(v_cart)),
                            'state', CASE WHEN p_state = 'NEW' THEN 'BROWSING' ELSE p_state END);
END $fn$;

-- ---------------------------------------------------------------- bakery notification helper
CREATE FUNCTION bakery._enqueue_bakery(p_order_id bigint, p_kind text, p_dedupe text) RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE v_notify text := bakery._setting_text('bakery_notify_wa_id', '');
BEGIN
  IF v_notify ~ '^[0-9]{6,20}$' THEN
    INSERT INTO bakery.notification_outbox(dedupe_key, kind, recipient_type, recipient_wa_id, order_id, payload)
    VALUES (p_dedupe, p_kind, 'BAKERY', v_notify, p_order_id, '{}'::jsonb) ON CONFLICT (dedupe_key) DO NOTHING;
  ELSE
    -- visible, replayable failure instead of a silently lost bakery notification (fix the setting, then fn_requeue_outbox)
    INSERT INTO bakery.notification_outbox(dedupe_key, kind, recipient_type, recipient_wa_id, order_id, payload, status, last_error_code, last_error)
    VALUES (p_dedupe, p_kind, 'BAKERY', '0000000000', p_order_id, '{}'::jsonb, 'DEAD', 'NOTIFY_NOT_CONFIGURED',
            'setting bakery_notify_wa_id is not a valid WhatsApp number') ON CONFLICT (dedupe_key) DO NOTHING;
  END IF;
END $fn$;

-- ---------------------------------------------------------------- order confirmation (single transaction)
-- All validation happens BEFORE the first write so early RETURNs never leave partial state.
CREATE FUNCTION bakery._confirm_order(p_cust bigint, p_cart_id bigint) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  cu bakery.customers%ROWTYPE; c bakery.carts%ROWTYPE; rec record; v_sub bigint := 0; v_fee bigint := 0; v_tax bigint; v_total bigint;
  v_oid bigint; v_ref text; v_tz text := bakery._setting_text('timezone', 'UTC'); v_err text; v_n int;
BEGIN
  SELECT * INTO cu FROM bakery.customers WHERE id = p_cust;
  SELECT * INTO c FROM bakery.carts WHERE id = p_cart_id AND status = 'OPEN' FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('code', 'NOTHING_TO_CONFIRM'); END IF;
  SELECT count(*) INTO v_n FROM bakery.cart_items WHERE cart_id = p_cart_id;
  IF v_n = 0 THEN RETURN jsonb_build_object('code', 'NOTHING_TO_CONFIRM'); END IF;
  IF c.fulfillment_method IS NULL OR c.requested_at IS NULL OR c.contact_name IS NULL
     OR (c.fulfillment_method = 'DELIVERY' AND c.delivery_address IS NULL) THEN
    RETURN jsonb_build_object('code', 'NEEDS_DETAILS');
  END IF;
  v_err := bakery._time_error(c.requested_at, p_cart_id);
  IF v_err IS NOT NULL THEN RETURN jsonb_build_object('code', 'TIME_INVALID', 'error', v_err); END IF;

  FOR rec IN
    SELECT ci.quantity, p.name, p.is_active, p.max_qty_per_order, v.is_active AS v_active, v.price_minor
      FROM bakery.cart_items ci JOIN bakery.products p ON p.id = ci.product_id JOIN bakery.product_variants v ON v.id = ci.variant_id
     WHERE ci.cart_id = p_cart_id ORDER BY ci.id
  LOOP
    IF NOT rec.is_active OR NOT rec.v_active THEN RETURN jsonb_build_object('code', 'UNAVAILABLE', 'name', rec.name); END IF;
    IF rec.quantity > rec.max_qty_per_order THEN RETURN jsonb_build_object('code', 'INVALID_QUANTITY', 'name', rec.name, 'max', rec.max_qty_per_order); END IF;
    v_sub := v_sub + rec.price_minor * rec.quantity;     -- trusted DB prices only
  END LOOP;

  SELECT p.name, p.stock_qty INTO rec
    FROM (SELECT product_id, sum(quantity) AS q FROM bakery.cart_items WHERE cart_id = p_cart_id GROUP BY product_id) s
    JOIN bakery.products p ON p.id = s.product_id
   WHERE p.stock_mode = 'TRACKED' AND p.stock_qty < s.q
   LIMIT 1 FOR UPDATE OF p;
  IF FOUND THEN RETURN jsonb_build_object('code', 'UNAVAILABLE', 'name', rec.name, 'available', rec.stock_qty); END IF;

  IF c.fulfillment_method = 'DELIVERY' THEN
    IF v_sub < bakery._setting_int('min_delivery_order_minor', 0) THEN
      RETURN jsonb_build_object('code', 'MIN_DELIVERY', 'min_minor', bakery._setting_int('min_delivery_order_minor', 0));
    END IF;
    v_fee := bakery._setting_int('delivery_fee_minor', 0);
  END IF;
  v_tax := (v_sub * bakery._setting_int('tax_rate_bps', 0) + 5000) / 10000;
  v_total := v_sub + v_fee + v_tax;

  -- ---- writes begin here ----
  v_ref := 'BK-' || to_char(now() AT TIME ZONE v_tz, 'YYMMDD') || '-' || lpad(nextval('bakery.order_ref_seq')::text, 5, '0')
           || '-' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 3));
  INSERT INTO bakery.orders(order_ref, customer_id, cart_id, fulfillment_method, requested_at, contact_name, contact_wa_id,
                            delivery_address, currency_code, subtotal_minor, delivery_fee_minor, tax_minor, total_minor)
  VALUES (v_ref, p_cust, p_cart_id, c.fulfillment_method, c.requested_at, c.contact_name, cu.wa_id,
          CASE WHEN c.fulfillment_method = 'DELIVERY' THEN c.delivery_address END,
          bakery._setting_text('currency_code', 'INR'), v_sub, v_fee, v_tax, v_total)
  RETURNING id INTO v_oid;
  INSERT INTO bakery.order_items(order_id, product_id, product_code, product_name, variant_label, unit_price_minor, quantity, line_total_minor, options)
  SELECT v_oid, p.id, p.code, p.name, v.label, v.price_minor, ci.quantity, v.price_minor * ci.quantity, ci.options
    FROM bakery.cart_items ci JOIN bakery.products p ON p.id = ci.product_id JOIN bakery.product_variants v ON v.id = ci.variant_id
   WHERE ci.cart_id = p_cart_id ORDER BY ci.id;
  UPDATE bakery.products p SET stock_qty = p.stock_qty - s.q
    FROM (SELECT product_id, sum(quantity)::int AS q FROM bakery.cart_items WHERE cart_id = p_cart_id GROUP BY product_id) s
   WHERE p.id = s.product_id AND p.stock_mode = 'TRACKED';
  INSERT INTO bakery.order_status_history(order_id, kind, from_status, to_status, changed_by, note)
  VALUES (v_oid, 'STATUS', NULL, 'CONFIRMED', 'customer', 'confirmed via WhatsApp');
  UPDATE bakery.carts SET status = 'CONFIRMED' WHERE id = p_cart_id;
  UPDATE bakery.customers SET saved_name = left(c.contact_name, 60) WHERE id = p_cust;

  -- notifications are rows in the SAME transaction; they are only sent after this transaction commits (Workflow D)
  INSERT INTO bakery.notification_outbox(dedupe_key, kind, recipient_type, recipient_wa_id, customer_id, order_id, payload)
  VALUES ('order:' || v_oid || ':confirmed:customer', 'ORDER_CONFIRMED_CUSTOMER', 'CUSTOMER', cu.wa_id, p_cust, v_oid, '{}'::jsonb)
  ON CONFLICT (dedupe_key) DO NOTHING;
  PERFORM bakery._enqueue_bakery(v_oid, 'ORDER_NEW_BAKERY', 'order:' || v_oid || ':confirmed:bakery');
  RETURN jsonb_build_object('code', 'ORDER_CONFIRMED', 'order_ref', v_ref, 'total_minor', v_total);
END $fn$;

CREATE FUNCTION bakery._act_cancel(p_cust bigint, p_intent jsonb, p_ctx jsonb, p_yes boolean) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE o bakery.orders%ROWTYPE; v_ref text := upper(nullif(btrim(coalesce(p_intent->>'order_ref', '')), '')); v_cart bigint;
        v_allowed boolean; v_r jsonb; v_ctx jsonb := coalesce(p_ctx, '{}'::jsonb);
BEGIN
  IF v_ref IS NULL THEN
    -- no order named: an open, unconfirmed cart is what "cancel my order" most likely refers to
    SELECT id INTO v_cart FROM bakery.carts WHERE customer_id = p_cust AND status = 'OPEN' AND expires_at > now()
       AND EXISTS (SELECT 1 FROM bakery.cart_items WHERE cart_id = carts.id);
    IF v_cart IS NOT NULL THEN
      UPDATE bakery.carts SET status = 'CLEARED' WHERE id = v_cart;
      RETURN jsonb_build_object('result', jsonb_build_object('code', 'CART_CANCELLED'), 'state', 'CANCELLED',
                                'ctx', v_ctx - 'awaiting' - 'pending_line' - 'summary_version' - 'pending_cancel');
    END IF;
    SELECT * INTO o FROM bakery.orders WHERE customer_id = p_cust AND status NOT IN ('COMPLETED','CANCELLED') ORDER BY created_at DESC LIMIT 1;
  ELSE
    SELECT * INTO o FROM bakery.orders WHERE order_ref = v_ref AND customer_id = p_cust;   -- ownership enforced here
  END IF;
  IF NOT FOUND THEN RETURN jsonb_build_object('result', jsonb_build_object('code', 'ORDER_NOT_FOUND')); END IF;
  IF o.status <> 'CONFIRMED' THEN
    RETURN jsonb_build_object('result', jsonb_build_object('code', 'CANCEL_NOT_ALLOWED', 'order_ref', o.order_ref, 'reason',
             CASE WHEN o.status IN ('COMPLETED','CANCELLED') THEN 'FINAL' ELSE 'IN_PROGRESS' END, 'status', o.status));
  END IF;
  v_allowed := (now() - o.created_at) <= (bakery._setting_int('cancel_window_minutes', 30) * interval '1 minute')
            OR (o.requested_at - now()) >= (bakery._setting_int('cancel_min_notice_hours', 24) * interval '1 hour');
  IF NOT v_allowed THEN
    RETURN jsonb_build_object('result', jsonb_build_object('code', 'CANCEL_NOT_ALLOWED', 'order_ref', o.order_ref, 'reason', 'TOO_LATE', 'status', o.status));
  END IF;
  IF NOT p_yes OR v_ctx->>'pending_cancel' IS DISTINCT FROM o.order_ref THEN
    RETURN jsonb_build_object('result', jsonb_build_object('code', 'CANCEL_ORDER_CONFIRM', 'order_ref', o.order_ref),
                              'ctx', v_ctx || jsonb_build_object('pending_cancel', o.order_ref));
  END IF;
  v_r := bakery.fn_set_order_status(o.order_ref, 'CANCELLED', 'customer', 'cancelled by customer via WhatsApp');
  IF NOT (v_r->>'ok')::boolean THEN
    RETURN jsonb_build_object('result', jsonb_build_object('code', 'CANCEL_NOT_ALLOWED', 'order_ref', o.order_ref, 'reason', 'IN_PROGRESS'));
  END IF;
  PERFORM bakery._enqueue_bakery(o.id, 'ORDER_CANCELLED_BAKERY', 'order:' || o.id || ':cancelled:bakery');
  -- the customer is told through the ORDER_STATUS_CUSTOMER outbox row created by fn_set_order_status
  RETURN jsonb_build_object('result', jsonb_build_object('code', 'ORDER_CANCELLED', 'order_ref', o.order_ref),
                            'state', 'CANCELLED', 'ctx', v_ctx - 'pending_cancel');
END $fn$;

CREATE FUNCTION bakery._act_status(p_cust bigint, p_intent jsonb) RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE v_ref text := upper(nullif(btrim(coalesce(p_intent->>'order_ref', '')), '')); v_orders jsonb;
        v_tz text := bakery._setting_text('timezone', 'UTC');
BEGIN
  SELECT jsonb_agg(jsonb_build_object('order_ref', x.order_ref, 'status', x.status, 'payment_status', x.payment_status,
           'fulfillment_method', x.fulfillment_method, 'total_minor', x.total_minor,
           'requested_local', to_char(x.requested_at AT TIME ZONE v_tz, 'Dy DD Mon YYYY, HH12:MI AM')) ORDER BY x.created_at DESC)
    INTO v_orders
    FROM (SELECT * FROM bakery.orders
           WHERE customer_id = p_cust AND (v_ref IS NULL OR order_ref = v_ref)   -- ownership: only this customer's orders are ever visible
           ORDER BY created_at DESC LIMIT 3) x;
  IF v_orders IS NULL THEN RETURN jsonb_build_object('result', jsonb_build_object('code', 'ORDER_NOT_FOUND')); END IF;
  RETURN jsonb_build_object('result', jsonb_build_object('code', 'ORDER_STATUS', 'orders', v_orders));
END $fn$;

CREATE FUNCTION bakery._act_menu(p_intent jsonb) RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE v_cat text := upper(nullif(btrim(coalesce(p_intent->>'category', '')), ''));
BEGIN
  IF v_cat IS NOT NULL AND v_cat IN ('CAKES','PASTRIES','COOKIES','BREAD','CUSTOM_CAKES') THEN
    RETURN jsonb_build_object('result', jsonb_build_object('code', 'MENU_ITEMS', 'category', v_cat, 'items',
      (SELECT coalesce(jsonb_agg(jsonb_build_object('code', t.code, 'name', t.name, 'description', t.description,
                'from_price_minor', t.from_price, 'variants', t.nv) ORDER BY t.sort_order, t.id), '[]'::jsonb)
         FROM (SELECT p.id, p.code, p.name, p.description, p.sort_order,
                      (SELECT min(v.price_minor) FROM bakery.product_variants v WHERE v.product_id = p.id AND v.is_active) AS from_price,
                      (SELECT count(*) FROM bakery.product_variants v WHERE v.product_id = p.id AND v.is_active) AS nv
                 FROM bakery.products p WHERE p.is_active AND p.category = v_cat ORDER BY p.sort_order, p.id LIMIT 10) t)));
  END IF;
  RETURN jsonb_build_object('result', jsonb_build_object('code', 'MENU_CATEGORIES', 'categories',
    (SELECT coalesce(jsonb_agg(jsonb_build_object('category', category, 'count', n) ORDER BY category), '[]'::jsonb)
       FROM (SELECT category, count(*) AS n FROM bakery.products WHERE is_active GROUP BY category) g)));
END $fn$;

-- ---------------------------------------------------------------- the entry point
CREATE FUNCTION bakery.fn_handle_inbound(p_event_id bigint, p_intent jsonb) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  ev bakery.webhook_event_log%ROWTYPE; cu bakery.customers%ROWTYPE; sess bakery.customer_sessions%ROWTYPE;
  v_prev jsonb; v_action text; v_intent jsonb; v_out jsonb; v_res jsonb; v_result jsonb; v_state text; v_ctx jsonb;
  v_cart bigint; v_cart_ver int; v_n int; v_expired boolean := false; v_raw text;
  v_actions text[] := ARRAY['GREET','HELP','MENU','ADD','REMOVE','CHANGE','CLEAR_CART','SHOW_CART','CHECKOUT','DETAILS','SET_OPTION',
                            'CONFIRM','DECLINE','CANCEL_ORDER','CANCEL_ORDER_YES','ORDER_STATUS','CANCEL_FLOW','TEXT','UNKNOWN'];
BEGIN
  SELECT * INTO ev FROM bakery.webhook_event_log WHERE id = p_event_id AND kind = 'MESSAGE';
  IF NOT FOUND THEN RAISE EXCEPTION 'message event % not found', p_event_id; END IF;

  -- serialise everything for one customer: no interleaved edits, no double confirmation
  PERFORM pg_advisory_xact_lock(hashtextextended('bakery:cust:' || ev.wa_id, 0));

  SELECT result INTO v_prev FROM bakery.processed_messages WHERE wa_message_id = ev.event_key;
  IF FOUND THEN RETURN v_prev || jsonb_build_object('replayed', true); END IF;

  INSERT INTO bakery.customers(wa_id, display_name, last_inbound_at)
  VALUES (ev.wa_id, left(nullif(btrim(ev.payload->>'name'), ''), 100), now())
  ON CONFLICT (wa_id) DO UPDATE SET display_name = coalesce(excluded.display_name, bakery.customers.display_name), last_inbound_at = now()
  RETURNING * INTO cu;
  INSERT INTO bakery.customer_sessions(customer_id) VALUES (cu.id) ON CONFLICT (customer_id) DO NOTHING;
  SELECT * INTO sess FROM bakery.customer_sessions WHERE customer_id = cu.id FOR UPDATE;
  v_state := sess.state; v_ctx := sess.context;

  -- per-customer rate limit (gateway-level limiting is still recommended)
  SELECT count(*) INTO v_n FROM bakery.webhook_event_log WHERE wa_id = ev.wa_id AND kind = 'MESSAGE' AND received_at > now() - interval '1 minute';
  IF v_n > bakery._setting_int('rate_limit_per_minute', 30) THEN
    IF EXISTS (SELECT 1 FROM bakery.processed_messages WHERE customer_id = cu.id AND processed_at > now() - interval '1 minute'
                  AND result->>'code' IN ('RATE_LIMITED','SILENT')) THEN
      v_result := jsonb_build_object('code', 'SILENT');
    ELSE
      v_result := jsonb_build_object('code', 'RATE_LIMITED');
    END IF;
    INSERT INTO bakery.processed_messages(wa_message_id, customer_id, result) VALUES (ev.event_key, cu.id, v_result) ON CONFLICT DO NOTHING;
    RETURN v_result;
  END IF;

  -- authoritative free text comes from the stored event, never from the (possibly AI-produced) intent
  v_raw := left(coalesce(ev.payload->>'text', ev.payload->>'interactive_title', ''), 300);
  v_intent := coalesce(p_intent, '{}'::jsonb) || jsonb_build_object('raw_text', v_raw);
  v_action := upper(coalesce(v_intent->>'action', 'UNKNOWN'));
  IF NOT (v_action = ANY (v_actions)) THEN v_action := 'UNKNOWN'; END IF;
  IF v_action = 'UNKNOWN' AND (v_ctx ? 'pending_line' OR v_ctx->>'awaiting' IS NOT NULL) THEN v_action := 'TEXT'; END IF;

  SELECT id, version INTO v_cart, v_cart_ver FROM bakery.carts WHERE customer_id = cu.id AND status = 'OPEN' AND expires_at > now();
  IF v_cart IS NULL AND EXISTS (SELECT 1 FROM bakery.carts WHERE customer_id = cu.id AND status = 'OPEN') THEN
    UPDATE bakery.carts SET status = 'EXPIRED' WHERE customer_id = cu.id AND status = 'OPEN';
    v_expired := true; v_state := 'BROWSING'; v_ctx := v_ctx - 'awaiting' - 'pending_line' - 'summary_version';
  END IF;
  IF v_state IN ('CANCELLED','ORDER_CONFIRMED') AND v_action NOT IN ('CONFIRM','ORDER_STATUS','CANCEL_ORDER','CANCEL_ORDER_YES') THEN
    v_state := 'BROWSING';
  END IF;
  IF v_action NOT IN ('CANCEL_ORDER','CANCEL_ORDER_YES') THEN v_ctx := v_ctx - 'pending_cancel'; END IF;

  IF v_action = 'GREET' THEN
    v_out := jsonb_build_object('result', jsonb_build_object('code', 'WELCOME', 'first_visit', v_state = 'NEW'),
                                'state', CASE WHEN v_state = 'NEW' THEN 'BROWSING' ELSE v_state END);
  ELSIF v_action = 'HELP' THEN
    v_out := jsonb_build_object('result', jsonb_build_object('code', 'HELP'), 'state', CASE WHEN v_state = 'NEW' THEN 'BROWSING' ELSE v_state END);
  ELSIF v_action = 'MENU' THEN
    v_out := bakery._act_menu(v_intent) || jsonb_build_object('state', CASE WHEN v_state IN ('NEW','CANCELLED','ORDER_CONFIRMED') THEN 'BROWSING' ELSE v_state END);
  ELSIF v_action = 'ADD' THEN
    v_out := bakery._act_add(cu.id, v_intent, v_ctx);
  ELSIF v_action = 'SET_OPTION' OR (v_action = 'TEXT' AND v_ctx ? 'pending_line') THEN
    IF v_ctx ? 'pending_line' THEN v_out := bakery._act_option(cu.id, v_intent, v_ctx);
    ELSE v_out := jsonb_build_object('result', jsonb_build_object('code', 'CLARIFY')); END IF;
  ELSIF v_action = 'REMOVE' THEN
    v_out := bakery._act_edit(cu.id, v_intent, v_ctx, true);
  ELSIF v_action = 'CHANGE' THEN
    v_out := bakery._act_edit(cu.id, v_intent, v_ctx, false);
  ELSIF v_action = 'CLEAR_CART' THEN
    IF v_cart IS NOT NULL THEN UPDATE bakery.carts SET status = 'CLEARED' WHERE id = v_cart; END IF;
    v_out := jsonb_build_object('result', jsonb_build_object('code', 'CART_CLEARED'), 'state', 'BROWSING',
                                'ctx', v_ctx - 'awaiting' - 'pending_line' - 'summary_version');
  ELSIF v_action = 'SHOW_CART' THEN
    IF v_cart IS NULL OR NOT EXISTS (SELECT 1 FROM bakery.cart_items WHERE cart_id = v_cart) THEN
      v_out := jsonb_build_object('result', jsonb_build_object('code', 'CART_EMPTY'));
    ELSE
      v_out := jsonb_build_object('result', jsonb_build_object('code', 'CART', 'cart', bakery._cart_json(v_cart)));
    END IF;
  ELSIF v_action = 'CHECKOUT' THEN
    IF v_cart IS NULL THEN v_out := jsonb_build_object('result', jsonb_build_object('code', 'CART_EMPTY'));
    ELSE v_out := bakery._progress_checkout(cu.id, v_cart, v_ctx); END IF;
  ELSIF v_action = 'DETAILS' THEN
    v_out := bakery._act_details(cu.id, v_intent, v_state, v_ctx);
  ELSIF v_action = 'TEXT' AND v_state = 'COLLECTING_CUSTOMER_DETAILS' AND v_ctx->>'awaiting' IN ('name','address','time','fulfillment') THEN
    IF v_ctx->>'awaiting' = 'name' THEN
      v_out := bakery._act_details(cu.id, jsonb_build_object('name', v_raw), v_state, v_ctx);
    ELSIF v_ctx->>'awaiting' = 'address' THEN
      v_out := bakery._act_details(cu.id, jsonb_build_object('address', v_raw), v_state, v_ctx);
    ELSIF v_ctx->>'awaiting' = 'time' THEN
      IF v_cart IS NULL THEN v_cart := bakery._get_or_create_cart(cu.id); END IF;
      v_out := jsonb_build_object('result', bakery._ask_detail(v_cart, 'time', 'INVALID_FORMAT'));
    ELSE
      IF v_cart IS NULL THEN v_cart := bakery._get_or_create_cart(cu.id); END IF;
      v_out := jsonb_build_object('result', bakery._ask_detail(v_cart, 'fulfillment', 'INVALID_FORMAT'));
    END IF;
  ELSIF v_action = 'CONFIRM' THEN
    IF v_state = 'ORDER_CONFIRMED' AND v_ctx ? 'last_order_ref' THEN
      v_out := jsonb_build_object('result', jsonb_build_object('code', 'ALREADY_CONFIRMED', 'order_ref', v_ctx->>'last_order_ref'));
    ELSIF v_cart IS NULL THEN
      v_out := jsonb_build_object('result', jsonb_build_object('code', 'NOTHING_TO_CONFIRM'));
    ELSIF v_state <> 'AWAITING_CONFIRMATION'
          OR coalesce((v_ctx->>'summary_version')::int, -1) <> v_cart_ver
          OR (nullif(v_intent->>'cart_version', '') IS NOT NULL AND (v_intent->>'cart_version') IS DISTINCT FROM v_cart_ver::text) THEN
      -- never confirm what the customer has not just seen: rebuild the summary (or ask for what is missing)
      v_out := bakery._progress_checkout(cu.id, v_cart, v_ctx);
      IF v_out->'result'->>'code' = 'REVIEW' THEN v_out := jsonb_set(v_out, '{result,stale}', 'true'::jsonb); END IF;
    ELSE
      v_res := bakery._confirm_order(cu.id, v_cart);
      IF v_res->>'code' = 'ORDER_CONFIRMED' THEN
        v_out := jsonb_build_object('result', v_res, 'state', 'ORDER_CONFIRMED', 'ctx', jsonb_build_object('last_order_ref', v_res->>'order_ref'));
      ELSIF v_res->>'code' IN ('NEEDS_DETAILS','TIME_INVALID','MIN_DELIVERY') THEN
        v_out := bakery._progress_checkout(cu.id, v_cart, v_ctx);
      ELSE
        v_out := jsonb_build_object('result', v_res, 'state', 'BUILDING_CART', 'ctx', v_ctx - 'summary_version');
      END IF;
    END IF;
  ELSIF v_action = 'DECLINE' THEN
    v_out := jsonb_build_object('result', jsonb_build_object('code', 'EDIT_PROMPT',
               'cart', CASE WHEN v_cart IS NULL THEN NULL ELSE bakery._cart_json(v_cart) END),
             'state', CASE WHEN v_cart IS NULL THEN 'BROWSING' ELSE 'BUILDING_CART' END,
             'ctx', v_ctx - 'awaiting' - 'pending_line' - 'summary_version');
  ELSIF v_action = 'CANCEL_FLOW' THEN
    v_out := jsonb_build_object('result', jsonb_build_object('code', 'FLOW_CANCELLED'),
             'state', CASE WHEN v_cart IS NOT NULL AND EXISTS (SELECT 1 FROM bakery.cart_items WHERE cart_id = v_cart) THEN 'BUILDING_CART' ELSE 'BROWSING' END,
             'ctx', v_ctx - 'awaiting' - 'pending_line' - 'summary_version');
  ELSIF v_action = 'CANCEL_ORDER' THEN
    v_out := bakery._act_cancel(cu.id, v_intent, v_ctx, false);
  ELSIF v_action = 'CANCEL_ORDER_YES' THEN
    v_out := bakery._act_cancel(cu.id, v_intent, v_ctx, true);
  ELSIF v_action = 'ORDER_STATUS' THEN
    v_out := bakery._act_status(cu.id, v_intent);
  ELSE
    v_out := jsonb_build_object('result', jsonb_build_object('code', 'CLARIFY'),
                                'state', CASE WHEN v_state = 'NEW' THEN 'BROWSING' ELSE v_state END);
  END IF;

  v_result := v_out->'result';
  IF v_out ? 'state' THEN v_state := v_out->>'state'; END IF;
  IF v_out ? 'ctx' THEN v_ctx := v_out->'ctx'; ELSE v_ctx := v_ctx; END IF;
  IF v_expired THEN v_result := v_result || jsonb_build_object('cart_expired', true); END IF;
  v_result := v_result || jsonb_build_object('state', v_state, 'awaiting', v_ctx->>'awaiting');

  UPDATE bakery.customer_sessions SET state = v_state, context = v_ctx WHERE customer_id = cu.id;
  INSERT INTO bakery.processed_messages(wa_message_id, customer_id, result) VALUES (ev.event_key, cu.id, v_result) ON CONFLICT DO NOTHING;
  RETURN v_result;
END $fn$;

INSERT INTO bakery.schema_migrations(version) VALUES ('003_functions_conversation');
COMMIT;
