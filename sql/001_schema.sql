-- 001_schema.sql | Bakery WhatsApp ordering | PostgreSQL 13+
-- NOT executed against a live PostgreSQL by the author. Run on a scratch database first.
-- Apply:  psql -v ON_ERROR_STOP=1 -d bakery -f 001_schema.sql
BEGIN;

CREATE SCHEMA IF NOT EXISTS bakery;

CREATE TABLE bakery.schema_migrations (
  version    text PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
);

-- configurable settings (NO SECRETS here; secrets live in n8n credentials / n8n environment)
CREATE TABLE bakery.bakery_settings (
  key         text PRIMARY KEY,
  value       jsonb NOT NULL,
  description text,
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE bakery.customers (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  wa_id           text NOT NULL UNIQUE CHECK (wa_id ~ '^[0-9]{6,20}$'),
  display_name    text CHECK (char_length(display_name) <= 100),
  saved_name      text CHECK (char_length(saved_name) <= 60),
  last_inbound_at timestamptz,
  erased_at       timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

-- one session row per customer => no cross-customer state leakage
CREATE TABLE bakery.customer_sessions (
  customer_id bigint PRIMARY KEY REFERENCES bakery.customers(id) ON DELETE CASCADE,
  state       text NOT NULL DEFAULT 'NEW' CHECK (state IN
              ('NEW','BROWSING','BUILDING_CART','COLLECTING_CUSTOMIZATION','COLLECTING_CUSTOMER_DETAILS',
               'REVIEWING_ORDER','AWAITING_CONFIRMATION','ORDER_CONFIRMED','CANCELLED')),
  context     jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE bakery.products (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code              text NOT NULL UNIQUE CHECK (code ~ '^[A-Z0-9-]{3,30}$'),
  category          text NOT NULL CHECK (category IN ('CAKES','PASTRIES','COOKIES','BREAD','CUSTOM_CAKES')),
  name              text NOT NULL CHECK (char_length(name) BETWEEN 2 AND 80),
  description       text CHECK (char_length(description) <= 300),
  is_active         boolean NOT NULL DEFAULT true,
  stock_mode        text NOT NULL DEFAULT 'MADE_TO_ORDER' CHECK (stock_mode IN ('MADE_TO_ORDER','TRACKED')),
  stock_qty         integer CHECK (stock_qty IS NULL OR stock_qty >= 0),
  max_qty_per_order integer NOT NULL DEFAULT 20 CHECK (max_qty_per_order BETWEEN 1 AND 100),
  lead_time_minutes integer NOT NULL DEFAULT 0 CHECK (lead_time_minutes BETWEEN 0 AND 43200),
  required_options  text[] NOT NULL DEFAULT '{}'
                    CHECK (required_options <@ ARRAY['flavor','egg','frosting','message']::text[]),
  sort_order        integer NOT NULL DEFAULT 100,
  is_demo           boolean NOT NULL DEFAULT true,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CHECK (stock_mode <> 'TRACKED' OR stock_qty IS NOT NULL)
);

-- every product has >= 1 variant; price lives on the variant
CREATE TABLE bakery.product_variants (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  product_id  bigint NOT NULL REFERENCES bakery.products(id) ON DELETE CASCADE,
  label       text NOT NULL CHECK (char_length(label) BETWEEN 1 AND 40),
  price_minor bigint NOT NULL CHECK (price_minor >= 0 AND price_minor <= 100000000),
  is_active   boolean NOT NULL DEFAULT true,
  sort_order  integer NOT NULL DEFAULT 100,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (product_id, label)
);

CREATE TABLE bakery.carts (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_id        bigint NOT NULL REFERENCES bakery.customers(id) ON DELETE CASCADE,
  status             text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','CONFIRMED','EXPIRED','CLEARED')),
  version            integer NOT NULL DEFAULT 1,
  fulfillment_method text CHECK (fulfillment_method IN ('PICKUP','DELIVERY')),
  requested_at       timestamptz,
  contact_name       text CHECK (char_length(contact_name) <= 60),
  delivery_address   text CHECK (char_length(delivery_address) <= 300),
  expires_at         timestamptz NOT NULL,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_carts_one_open_per_customer ON bakery.carts (customer_id) WHERE status = 'OPEN';
CREATE INDEX ix_carts_open_expiry ON bakery.carts (expires_at) WHERE status = 'OPEN';

CREATE TABLE bakery.cart_items (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  cart_id    bigint NOT NULL REFERENCES bakery.carts(id) ON DELETE CASCADE,
  product_id bigint NOT NULL REFERENCES bakery.products(id),
  variant_id bigint NOT NULL REFERENCES bakery.product_variants(id),
  quantity   integer NOT NULL CHECK (quantity BETWEEN 1 AND 100),
  options    jsonb NOT NULL DEFAULT '{}'::jsonb,
  line_key   text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (cart_id, line_key)
);
CREATE INDEX ix_cart_items_cart ON bakery.cart_items (cart_id);

CREATE SEQUENCE bakery.order_ref_seq START 1;

CREATE TABLE bakery.orders (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  order_ref          text NOT NULL UNIQUE,
  customer_id        bigint NOT NULL REFERENCES bakery.customers(id),
  cart_id            bigint NOT NULL UNIQUE REFERENCES bakery.carts(id),  -- one order per cart = confirmation idempotency
  status             text NOT NULL DEFAULT 'CONFIRMED' CHECK (status IN
                     ('CONFIRMED','PREPARING','READY','OUT_FOR_DELIVERY','COMPLETED','CANCELLED')),
  payment_status     text NOT NULL DEFAULT 'PAYMENT_PENDING' CHECK (payment_status IN
                     ('PAYMENT_PENDING','PAID','FAILED','REFUNDED')),
  fulfillment_method text NOT NULL CHECK (fulfillment_method IN ('PICKUP','DELIVERY')),
  requested_at       timestamptz NOT NULL,
  contact_name       text NOT NULL,
  contact_wa_id      text NOT NULL,
  delivery_address   text,
  currency_code      char(3) NOT NULL,
  subtotal_minor     bigint NOT NULL CHECK (subtotal_minor >= 0),
  discount_minor     bigint NOT NULL DEFAULT 0 CHECK (discount_minor >= 0),
  delivery_fee_minor bigint NOT NULL DEFAULT 0 CHECK (delivery_fee_minor >= 0),
  tax_minor          bigint NOT NULL DEFAULT 0 CHECK (tax_minor >= 0),
  total_minor        bigint NOT NULL CHECK (total_minor >= 0),
  cancel_reason      text,
  cancelled_at       timestamptz,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CHECK (total_minor = subtotal_minor - discount_minor + delivery_fee_minor + tax_minor),
  CHECK (fulfillment_method <> 'DELIVERY' OR delivery_address IS NOT NULL)
);
CREATE INDEX ix_orders_customer ON bakery.orders (customer_id, created_at DESC);
CREATE INDEX ix_orders_active_status ON bakery.orders (status) WHERE status NOT IN ('COMPLETED','CANCELLED');

-- immutable snapshot of name/price at order time
CREATE TABLE bakery.order_items (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  order_id         bigint NOT NULL REFERENCES bakery.orders(id) ON DELETE CASCADE,
  product_id       bigint REFERENCES bakery.products(id) ON DELETE SET NULL,
  product_code     text NOT NULL,
  product_name     text NOT NULL,
  variant_label    text NOT NULL,
  unit_price_minor bigint NOT NULL CHECK (unit_price_minor >= 0),
  quantity         integer NOT NULL CHECK (quantity BETWEEN 1 AND 100),
  line_total_minor bigint NOT NULL CHECK (line_total_minor = unit_price_minor * quantity),
  options          jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX ix_order_items_order ON bakery.order_items (order_id);

-- durable intake queue; minimal normalized payload; purged by retention policy
CREATE TABLE bakery.webhook_event_log (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  event_key    text NOT NULL UNIQUE,   -- wamid for messages, "<wamid>:<status>" for status events
  kind         text NOT NULL CHECK (kind IN ('MESSAGE','STATUS')),
  wa_id        text CHECK (wa_id ~ '^[0-9]{6,20}$'),
  msg_type     text CHECK (char_length(msg_type) <= 30),
  event_ts     timestamptz,
  payload      jsonb NOT NULL DEFAULT '{}'::jsonb,
  status       text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','PROCESSING','DONE','DEAD','IGNORED')),
  attempts     integer NOT NULL DEFAULT 0,
  claimed_at   timestamptz,
  last_error   text,
  received_at  timestamptz NOT NULL DEFAULT now(),
  processed_at timestamptz,
  payload_purged_at timestamptz
);
CREATE INDEX ix_events_open ON bakery.webhook_event_log (received_at) WHERE status IN ('PENDING','PROCESSING');
CREATE INDEX ix_events_wa_recent ON bakery.webhook_event_log (wa_id, received_at DESC);

-- idempotency: stores the handler result so a replay re-renders the same reply without re-mutating state
CREATE TABLE bakery.processed_messages (
  wa_message_id text PRIMARY KEY,
  customer_id   bigint REFERENCES bakery.customers(id) ON DELETE SET NULL,
  result        jsonb NOT NULL DEFAULT '{}'::jsonb,
  processed_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_processed_customer ON bakery.processed_messages (customer_id, processed_at DESC);

-- every outbound WhatsApp message goes through the outbox
CREATE TABLE bakery.notification_outbox (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  dedupe_key          text NOT NULL UNIQUE,
  kind                text NOT NULL CHECK (kind IN
                      ('REPLY','ORDER_CONFIRMED_CUSTOMER','ORDER_NEW_BAKERY','ORDER_STATUS_CUSTOMER','ORDER_CANCELLED_BAKERY')),
  recipient_type      text NOT NULL CHECK (recipient_type IN ('CUSTOMER','BAKERY')),
  recipient_wa_id     text NOT NULL CHECK (recipient_wa_id ~ '^[0-9]{6,20}$'),
  customer_id         bigint REFERENCES bakery.customers(id) ON DELETE SET NULL,
  order_id            bigint REFERENCES bakery.orders(id) ON DELETE SET NULL,
  payload             jsonb NOT NULL DEFAULT '{}'::jsonb,
  status              text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','PROCESSING','SENT','DEAD','BLOCKED_WINDOW')),
  attempts            integer NOT NULL DEFAULT 0,
  next_attempt_at     timestamptz NOT NULL DEFAULT now(),
  locked_at           timestamptz,
  provider_message_id text,
  delivery_status     text,
  delivery_error      text,
  last_error_code     text,
  last_error          text,
  sent_at             timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_outbox_pending ON bakery.notification_outbox (next_attempt_at, id) WHERE status = 'PENDING';
CREATE INDEX ix_outbox_processing ON bakery.notification_outbox (locked_at) WHERE status = 'PROCESSING';
CREATE INDEX ix_outbox_provider_id ON bakery.notification_outbox (provider_message_id) WHERE provider_message_id IS NOT NULL;
CREATE INDEX ix_outbox_dead ON bakery.notification_outbox (id) WHERE status IN ('DEAD','BLOCKED_WINDOW');

CREATE TABLE bakery.order_status_history (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  order_id    bigint NOT NULL REFERENCES bakery.orders(id) ON DELETE CASCADE,
  kind        text NOT NULL DEFAULT 'STATUS' CHECK (kind IN ('STATUS','PAYMENT')),
  from_status text,
  to_status   text NOT NULL,
  changed_by  text NOT NULL,
  note        text,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_status_history_order ON bakery.order_status_history (order_id, created_at);

-- written by Workflow F (redacted; no payloads)
CREATE TABLE bakery.error_log (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  occurred_at    timestamptz NOT NULL DEFAULT now(),
  workflow_name  text,
  execution_id   text,
  node_name      text,
  classification text,
  message        text,
  order_ref      text
);
CREATE INDEX ix_error_log_time ON bakery.error_log (occurred_at DESC);

CREATE FUNCTION bakery.touch_updated_at() RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN NEW.updated_at := now(); RETURN NEW; END $fn$;

DO $do$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['bakery_settings','customers','customer_sessions','products','product_variants',
                           'carts','cart_items','orders','notification_outbox'] LOOP
    EXECUTE format('CREATE TRIGGER trg_%1$s_touch BEFORE UPDATE ON bakery.%1$I FOR EACH ROW EXECUTE FUNCTION bakery.touch_updated_at()', t);
  END LOOP;
END $do$;

INSERT INTO bakery.schema_migrations(version) VALUES ('001_schema');
COMMIT;
