-- 004_seed_demo.sql | FICTIONAL bakery + DEMONSTRATION prices only (never real market prices).
-- Money is stored in minor units (paise): 45000 = 450.00. Safe to re-run: uses ON CONFLICT.
BEGIN;

INSERT INTO bakery.bakery_settings(key, value, description) VALUES
 ('bakery_name',            '"Demo Crumb & Co. (FICTIONAL)"', 'shown in messages'),
 ('bakery_contact',         '{"phone":"+00 00000 00000","address":"1 Demo Street, Example City"}', 'placeholder contact; replace'),
 ('currency_code',          '"INR"', 'ISO 4217'),
 ('currency_symbol',        '"₹"',   'display symbol'),
 ('timezone',               '"Asia/Kolkata"', 'IANA time zone used for opening hours and display'),
 ('opening_hours',          '{"1":["09:00","20:00"],"2":["09:00","20:00"],"3":["09:00","20:00"],"4":["09:00","20:00"],"5":["09:00","20:00"],"6":["09:00","20:00"],"7":["10:00","18:00"]}', 'ISO weekday (1=Mon..7=Sun) -> [open, close] or null when closed'),
 ('pickup_enabled',         'true',  'pickup available'),
 ('delivery_enabled',       'true',  'delivery available'),
 ('delivery_fee_minor',     '4000',  'DEMO value'),
 ('min_delivery_order_minor','30000','DEMO value; delivery needs at least this subtotal'),
 ('tax_rate_bps',           '0',     'tax in basis points (500 = 5%); 0 = prices already include tax'),
 ('min_lead_minutes',       '120',   'minimum notice for any order'),
 ('max_advance_days',       '30',    'how far ahead customers may order'),
 ('cart_ttl_minutes',       '120',   'abandoned-cart expiry, refreshed on every cart change'),
 ('cake_flavors',           '["Chocolate","Vanilla","Butterscotch","Red Velvet","Pineapple"]', 'custom cake flavors'),
 ('cake_frostings',         '["Buttercream","Whipped Cream","Chocolate Ganache"]', 'custom cake frostings'),
 ('egg_options',            '["Egg","Eggless"]', 'egg preference'),
 ('cake_message_max_len',   '40',    'max characters written on a cake'),
 ('cancel_window_minutes',  '30',    'customer may cancel freely this long after confirming'),
 ('cancel_min_notice_hours','24',    'or any time until this many hours before the requested time'),
 ('payment_instructions',   '"Payment is collected when you pick up or receive your order. (Demo setting.)"', 'shown after confirmation'),
 ('bakery_notify_wa_id',    'null',  'digits only, e.g. 919876543210. MUST be set before testing bakery notifications'),
 ('bakery_notify_template', '{"name":"hello_world","language":"en_US","params":[]}', 'approved template used when the 24h window is closed. hello_world exists on Meta test numbers. params: any of order_ref, summary, total'),
 ('customer_status_template','{"name":"hello_world","language":"en_US","params":[]}', 'template for customer notifications outside the 24h window'),
 ('rate_limit_per_minute',  '30',    'inbound messages per customer per minute'),
 ('outbox_max_attempts',    '6',     'send attempts before dead-lettering'),
 ('event_max_attempts',     '5',     'processing attempts before an inbound event is dead-lettered'),
 ('event_retention_days',   '14',    'webhook_event_log rows kept this long (Meta retries for up to ~7 days)'),
 ('payload_retention_days', '7',     'message text is wiped after this many days'),
 ('outbox_retention_days',  '30',    'sent notifications kept this long'),
 ('ai_enabled',             'false', 'optional LLM intent parsing; deterministic parser is always used first'),
 ('ai_model',               '"REPLACE_WITH_MODEL_ID"', 'model id for the LLM provider; no default on purpose'),
 ('ai_timeout_ms',          '15000', 'LLM request timeout')
ON CONFLICT (key) DO NOTHING;

CREATE TEMP TABLE _seed(code text, category text, name text, description text, active boolean, mode text, stock int, maxq int, lead int, req text[], sort int);
INSERT INTO _seed VALUES
 ('CAKE-CHOC-01','CAKES','Chocolate Truffle Cake','Rich chocolate sponge with truffle cream (demo).',true,'MADE_TO_ORDER',NULL,5,240,'{}',10),
 ('CAKE-VAN-01','CAKES','Classic Vanilla Cake','Soft vanilla sponge with whipped cream (demo).',true,'MADE_TO_ORDER',NULL,5,240,'{}',20),
 ('CAKE-RV-01','CAKES','Red Velvet Cake','Red velvet layers with cream-cheese frosting (demo).',true,'MADE_TO_ORDER',NULL,5,240,'{}',30),
 ('PAS-CHOC-01','PASTRIES','Chocolate Pastry','Single-serve chocolate pastry (demo).',true,'MADE_TO_ORDER',NULL,24,0,'{}',10),
 ('PAS-FRUIT-01','PASTRIES','Fruit Cream Pastry','Fresh fruit and cream pastry (demo).',true,'MADE_TO_ORDER',NULL,24,0,'{}',20),
 ('PAS-BFOR-01','PASTRIES','Black Forest Pastry','Cherry and chocolate pastry; stock-tracked demo item.',true,'TRACKED',24,24,0,'{}',30),
 ('COK-OAT-01','COOKIES','Oatmeal Raisin Cookies','Chewy oatmeal cookies (demo).',true,'MADE_TO_ORDER',NULL,10,0,'{}',10),
 ('COK-CHIP-01','COOKIES','Choco Chip Cookies','Classic chocolate chip cookies (demo).',true,'MADE_TO_ORDER',NULL,10,0,'{}',20),
 ('BRD-WHT-01','BREAD','White Sandwich Loaf','Soft white sandwich loaf (demo).',true,'MADE_TO_ORDER',NULL,10,0,'{}',10),
 ('BRD-MLT-01','BREAD','Multigrain Loaf','Seeded multigrain loaf (demo).',true,'MADE_TO_ORDER',NULL,10,0,'{}',20),
 ('BRD-SEAS-01','BREAD','Seasonal Fruit Bread','Currently unavailable - used to test the unavailable-product path.',false,'MADE_TO_ORDER',NULL,10,0,'{}',30),
 ('CUS-BDAY-01','CUSTOM_CAKES','Custom Birthday Cake','Choose flavor, egg/eggless, frosting and a message (demo).',true,'MADE_TO_ORDER',NULL,3,1440,'{flavor,egg,frosting,message}',10),
 ('CUS-THEME-01','CUSTOM_CAKES','Custom Theme Cake','Themed cake; same options as the birthday cake (demo).',true,'MADE_TO_ORDER',NULL,3,2880,'{flavor,egg,frosting,message}',20);

INSERT INTO bakery.products(code, category, name, description, is_active, stock_mode, stock_qty, max_qty_per_order, lead_time_minutes, required_options, sort_order)
SELECT code, category, name, description, active, mode, stock, maxq, lead, req, sort FROM _seed
ON CONFLICT (code) DO NOTHING;

CREATE TEMP TABLE _var(code text, label text, price bigint, sort int);
INSERT INTO _var VALUES
 ('CAKE-CHOC-01','0.5 kg',45000,10),('CAKE-CHOC-01','1 kg',85000,20),('CAKE-CHOC-01','2 kg',160000,30),
 ('CAKE-VAN-01','0.5 kg',38000,10),('CAKE-VAN-01','1 kg',72000,20),('CAKE-VAN-01','2 kg',138000,30),
 ('CAKE-RV-01','0.5 kg',52000,10),('CAKE-RV-01','1 kg',98000,20),
 ('PAS-CHOC-01','Piece',9000,10),('PAS-FRUIT-01','Piece',8500,10),('PAS-BFOR-01','Piece',9500,10),
 ('COK-OAT-01','Box of 6',18000,10),('COK-OAT-01','Box of 12',34000,20),
 ('COK-CHIP-01','Box of 6',20000,10),('COK-CHIP-01','Box of 12',38000,20),
 ('BRD-WHT-01','Loaf',6000,10),('BRD-MLT-01','Loaf',8500,10),('BRD-SEAS-01','Loaf',11000,10),
 ('CUS-BDAY-01','1 kg',110000,10),('CUS-BDAY-01','2 kg',210000,20),('CUS-BDAY-01','3 kg',300000,30),
 ('CUS-THEME-01','1 kg',130000,10),('CUS-THEME-01','2 kg',250000,20);
INSERT INTO bakery.product_variants(product_id, label, price_minor, sort_order)
SELECT p.id, v.label, v.price, v.sort FROM _var v JOIN bakery.products p ON p.code = v.code
ON CONFLICT (product_id, label) DO NOTHING;

INSERT INTO bakery.schema_migrations(version) VALUES ('004_seed_demo') ON CONFLICT DO NOTHING;
COMMIT;
