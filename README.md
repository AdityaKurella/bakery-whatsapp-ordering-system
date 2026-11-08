# Bakery WhatsApp Ordering System — n8n 2.22.6 + PostgreSQL

WhatsApp bakery ordering automation built with six n8n workflows and PostgreSQL. The repository includes SQL migrations, JavaScript Code-node sources, sample webhook payloads, static validation, and unit tests. Local validation passes, including 179 JavaScript behavior assertions.

---
## 1. Architecture and assumptions

```
Meta Cloud API ──GET──► [A verify]                       (same URL, different HTTP method)
Meta Cloud API ──POST─► [B intake] verify HMAC(raw body) → store events in PostgreSQL → ACK 200 → ─┐
                                                                                                   ▼
                                   [C conversation engine]  claim event → parse intent (rules; optional LLM) →
                                   bakery.fn_handle_inbound() (state machine, cart, prices, orders: ONE transaction) →
                                   render replies → write to notification_outbox → call D
[D dispatcher]  claim outbox rows (SKIP LOCKED) → build Cloud API request → send → classify → record (retry/backoff/dead-letter)
                + staff API  POST /webhook/bakery-order-status  (status / payment updates)
[E maintenance] every 5 min: expire carts, un-stick outbox, replay stale events, retention, de-duplicated alerts
[F error handler] classify + redact + log + alert
```

**Key design decisions**
- **PostgreSQL is the brain.** Cart, prices, availability, state machine, order creation, idempotency and ownership checks live in PL/pgSQL (`sql/003`). n8n only parses, renders and sends. A function call is the only way to get a real transaction through the n8n Postgres node (it runs one parameterised statement per item).
- **The LLM is optional and advisory.** Rules parse first. The LLM runs only if the rules return UNKNOWN **and** `ai_enabled=true` **and** a model id is set (default: off). Its output is allow-listed (it cannot confirm, cancel, set price/time/address) and re-validated by the database.
- **Durable intake:** events are written to `webhook_event_log` *before* the 200 ACK. If that write fails we return 503 and Meta redelivers. Duplicates are dropped by a unique key on the WhatsApp message id.
- **Exactly-once *effect* for state changes** (not exactly-once delivery): `processed_messages` stores each handler result in the same transaction as the state change, so a replay re-renders the same reply without mutating anything.
- **Outbound is at-least-once.** Replies and notifications are rows in `notification_outbox`, sent only after the order transaction has committed. A crash between "sent" and "recorded" can produce a duplicate message; it cannot produce a duplicate order.
- **Explicit confirmation:** the summary shows `CONFIRM:<cart version>`. A stale button, or a typed "confirm" when no current summary was shown, re-displays the summary instead of ordering.
- **Prices:** integer minor units (`bigint`), only from `product_variants`. Tax is an optional basis-points setting.
- **Target n8n version: 2.22.6.** Workflow node versions: Webhook 2, Code 2, IF 2.2, Respond to Webhook 1.4, Postgres 2.5, HTTP Request 4.2, Execute Workflow 1.2, Execute Workflow Trigger 1.1, Schedule Trigger 1.2, Error Trigger 1, Manual Trigger 1, Sticky Note 1.
- **Webhook routing:** workflows A (GET verification) and B (POST intake) use the same path; n8n routes them by HTTP method and path.

## 2. File manifest

| File | Purpose |
|---|---|
| `sql/001_schema.sql` | 15 tables, constraints, indexes, triggers (the 12 required + `bakery_settings`, `error_log`, `schema_migrations`) |
| `sql/002_functions_core.sql` | settings, event intake, claim, outbox claim/record, order status, maintenance, erasure |
| `sql/003_functions_conversation.sql` | state machine, cart, checkout, order confirmation, cancellation, status |
| `sql/004_seed_demo.sql` | fictional bakery, 13 products (1 inactive), settings. **Demo prices only** |
| `sql/005_roles_optional.sql` | least-privilege `bakery_app` role |
| `sql/900_rollback.sql` | drops everything (back up first) |
| `workflows/A…F_*.json` | six importable n8n exports (all `active: false`) |
| `src/*.js` | Code-node sources (embedded into the JSON by `tools/build_workflows.py`) |
| `tools/build_workflows.py`, `validate.py`, `sign_and_post.py` | rebuild, static-validate, send signed test webhooks |
| `tests/unit_test.js` | 179 assertions on the Code-node JS (`node tests/unit_test.js`) |
| `tests/sql_smoke_test.sql` | Database smoke test with 54 expectations, rolled back at the end |
| `tests/payloads/*.json` | Meta-format sample payloads (dummy ids/numbers) |

## 3. Prerequisites you must confirm
1. **PostgreSQL 13+** reachable from n8n. Easiest for local testing: add a `postgres:16` container on the same Docker network as n8n; from n8n use host `postgres` (not `localhost`).
2. **Public HTTPS URL** for Meta to reach n8n (local test: a tunnel such as cloudflared or ngrok → `localhost:5678`). Set `WEBHOOK_URL=https://your-public-host/` on n8n so it shows correct URLs.
3. A Meta app with the WhatsApp product, a **test phone number**, and your own phone added to the test number's allowed recipients.

## 4. Environment variables (n8n container)

n8n 2.x **blocks `$env` in Code nodes and expressions by default**, and Code nodes cannot `require('crypto')` unless allowed. Community edition has no external-secrets store, so the secrets below live in the n8n container's environment. **Anyone who can edit workflows can read them** — restrict editor access, and use the strict alternative in §8 if that is unacceptable.

| Variable | Value | Used by |
|---|---|---|
| `N8N_BLOCK_ENV_ACCESS_IN_NODE` | `false` | all (required for `$env`) |
| `NODE_FUNCTION_ALLOW_BUILTIN` | `crypto` | B signature check. Default internal task-runner mode: set on the n8n container. External runner mode: set on the runner container too |
| `META_APP_SECRET` | Meta app → Settings → Basic → App secret | B (HMAC) |
| `META_VERIFY_TOKEN` | random, ≥16 chars, you invent it | A |
| `META_PHONE_NUMBER_ID` | WhatsApp → API Setup → Phone number ID | B (filters other numbers), D (send URL) |
| `WHATSAPP_API_VERSION` | e.g. `v21.0` — **look up a currently supported version in Meta's docs** | D |
| `ALERT_WEBHOOK_URL` | optional Slack/Discord incoming-webhook URL | E, F |
| `WEBHOOK_URL`, `N8N_PROXY_HOPS=1` | public base URL; set when behind a reverse proxy | n8n |

Docker example (adjust to how you run n8n; **do not commit real values**):
```
docker run ... -e N8N_BLOCK_ENV_ACCESS_IN_NODE=false -e NODE_FUNCTION_ALLOW_BUILTIN=crypto \
  -e META_APP_SECRET=... -e META_VERIFY_TOKEN=... -e META_PHONE_NUMBER_ID=... -e WHATSAPP_API_VERSION=v21.0 \
  -e WEBHOOK_URL=https://your-public-host/ ...
```

## 5. n8n credentials (create these first; exports contain names only, no ids/secrets)
| Credential name (exact) | Type | Content |
|---|---|---|
| `Bakery Postgres` | Postgres | host/db/user/password (use `bakery_app` from `005`) |
| `WhatsApp Cloud Bearer` | Header Auth | Name `Authorization`, Value `Bearer <META_ACCESS_TOKEN>`. Test-number temporary tokens expire in ~24 h |
| `Bakery Staff Webhook Key` | Header Auth | Name `X-Bakery-Key`, Value = long random string |
| `Anthropic API Key` | Header Auth | Name `x-api-key` — only if you enable AI |

After import, open each node that shows a red credential warning and pick the credential.

## 6. Database setup
```
createdb bakery
psql -v ON_ERROR_STOP=1 -d bakery -f sql/001_schema.sql
psql -v ON_ERROR_STOP=1 -d bakery -f sql/002_functions_core.sql
psql -v ON_ERROR_STOP=1 -d bakery -f sql/003_functions_conversation.sql
psql -v ON_ERROR_STOP=1 -d bakery -f sql/004_seed_demo.sql
psql -v ON_ERROR_STOP=1 -d bakery -f tests/sql_smoke_test.sql        # expect: NOTICE: SMOKE TEST PASSED
psql -v ON_ERROR_STOP=1 -v app_password='STRONG_PASSWORD' -d bakery -f sql/005_roles_optional.sql
```
**Run the smoke test and resolve any reported failures before connecting n8n.** Then set the bakery notification target (digits only, with country code; the number must be allowed on your test setup):
```sql
UPDATE bakery.bakery_settings SET value = '"919800000099"' WHERE key = 'bakery_notify_wa_id';
```
Change other settings the same way (`opening_hours`, `timezone`, `delivery_fee_minor`, `min_lead_minutes`, `cake_flavors`, …). Unconfigured bakery notification → the outbox row is created as `DEAD / NOTIFY_NOT_CONFIGURED` (visible, alerting, replayable after you set it) rather than silently lost.

**Migration/rollback:** migrations are forward-only and wrapped in transactions. To undo, restore a backup (`pg_restore`) or run `900_rollback.sql` on a scratch DB. Always `pg_dump -Fc` before changing a database that holds real orders.

## 7. Import and wiring (order matters because of workflow ids)
1. Import **F**, then **D**, **C**, **E**, **B**, **A** (Workflows → Import from file). All arrive inactive.
2. Note each workflow's id from its URL (`/workflow/<id>`).
3. In **C**: node *Dispatch Now (Workflow D)* → set workflow to **D**. In **B**: *Process Event (Workflow C)* → **C**. In **E**: *Replay Event (Workflow C)* → **C**. (They contain `REPLACE_WITH_WORKFLOW_*_ID` placeholders until you do.)
4. Select credentials on every node that asks (Postgres in B–F; WhatsApp in D; Header Auth on D's *Staff Status Webhook*; Anthropic in C only if AI is used).
5. In workflows **A–E**: Settings → *Error Workflow* → **F**.
6. Execution data: all workflows are saved with `saveDataSuccessExecution: none` to avoid keeping message text. While debugging with dummy data you may switch a workflow to *all*; set it back afterwards, and set `EXECUTIONS_DATA_PRUNE=true` / `EXECUTIONS_DATA_MAX_AGE`.
7. **Activation sequence:** F (no trigger to activate besides being selected as error workflow) → D → E → B → A. C is only called by others and need not be active. Keep the real business number disabled during test-number setup; activate B and A for the Meta test number, because Meta calls the production URL.

## 8. Webhook signature verification (what is and isn't guaranteed)
- Workflow B turns on the Webhook node's **Raw Body** option, reads the raw bytes, computes `HMAC-SHA256(META_APP_SECRET, rawBody)`, compares timing-safely with `X-Hub-Signature-256`, and only then parses that same buffer. It **fails closed**: no secret, no raw body, or `crypto` not allowed → 403.
- Workflow B reads the raw request bytes from the Webhook node's binary input, computes the signature, and validates it before parsing the payload. Use `tools/sign_and_post.py` to send a signed test payload; if validation rejects it, inspect the *Verify Signature* execution and read `reason`.
- **Stricter alternative** (no secrets in n8n): terminate TLS in nginx/Caddy/Cloudflare Worker, verify the signature there, and forward only verified requests to n8n; then remove the check in B.
- Gateway rate limiting is recommended (e.g. nginx `limit_req`) in addition to the per-customer limit inside the database.

## 9. Meta Developer setup
1. developers.facebook.com → your app → WhatsApp → API Setup: copy **Phone number ID**, add your phone as a recipient, generate a (temporary) access token → put it in the `WhatsApp Cloud Bearer` credential.
2. WhatsApp → Configuration → Webhook: Callback URL `https://YOUR-HOST/webhook/whatsapp-bakery`, Verify token = `META_VERIFY_TOKEN`. Click *Verify and save* (hits Workflow A). Subscribe to the **messages** field.
3. Send "hi" from your phone to the test number. Within seconds you should get the welcome message.
4. The bakery notification recipient must also be allowed on the test number. Outside the 24 h window only approved templates can be sent: the seed uses Meta's built-in `hello_world` template (no parameters) so notifications work on a test number; replace with your own approved template and set `params` (`order_ref`, `summary`, `total`) for real use. To receive free-form bakery alerts, message the bot once from the staff phone (this opens that phone's 24 h window).
5. Test URLs (`/webhook-test/...`) only work while the editor is "listening" on one workflow; because Meta needs both GET and POST, use the production URLs on the test number, and use `sign_and_post.py` against `/webhook-test/` for dry runs.

## 10. Local validation

| Check | Result |
|---|---|
| Workflow structure, JSON parsing, node connections, credential references, and embedded secret patterns | Passed with `python tools/validate.py` |
| JavaScript syntax for all 13 Code nodes | Passed as part of static validation |
| PostgreSQL query parameter counts and referenced function names | Passed as part of static validation |
| JavaScript behavior assertions for parsing, signature verification, event normalization, rendering, response classification, AI validation, and error redaction | 179 passed with `node tests/unit_test.js` |

## 11. Deployment and operations

**Backup/restore:** `pg_dump -Fc -d bakery -f bakery_$(date +%F).dump` daily and before migrations. Restore a backup with `createdb bakery_restore && pg_restore -d bakery_restore bakery_….dump`, then run a few `SELECT count(*)` checks.

**Recovery runbook**
- Dead letters: run workflow E's manual branch, or `SELECT * FROM bakery.v_dead_letters;`
- Replay a dead inbound event: `SELECT bakery.fn_replay_dead_event(<id>);` — replay failed notifications with `SELECT bakery.fn_requeue_outbox(<id>);` or by cause with `SELECT bakery.fn_requeue_dead_outbox('AUTH');` (`CONFIG`, `NOTIFY_NOT_CONFIGURED`, …)
- Order without a bakery notification: find its `notification_outbox` rows with status DEAD/BLOCKED_WINDOW and requeue; the order itself is never recreated.
- Retention defaults: message text is wiped after 7 days, events are deleted after 14, idempotency keys are kept at least 30 days, and sent outbox/error log rows are kept 30 days. Confirmed orders are not deleted by maintenance. `bakery.fn_erase_customer('<wa_id>')` anonymizes orders.

**Cost drivers:** WhatsApp conversation/message charges, hosting for n8n and PostgreSQL with public HTTPS, optional LLM tokens, and backup storage.

**Rollback:** deactivate B (Meta retries for a while and events resume when reactivated), restore previous workflow JSON files and the database dump if needed.

## Staff order-status API

```sh
curl -X POST https://HOST/webhook/bakery-order-status -H "X-Bakery-Key: $KEY" -H 'Content-Type: application/json' \
  -d '{"order_ref":"BK-261024-00001-A3F","status":"PREPARING","actor":"Asha"}'
curl ... -d '{"order_ref":"BK-...","payment_status":"PAID","actor":"Asha","note":"UPI ref checked manually"}'
```

Payment changes are handled through the staff endpoint or SQL rather than customer messages.
## 12. Troubleshooting
| Symptom | Likely cause |
|---|---|
| Meta "Verify and save" fails | `META_VERIFY_TOKEN` unset/short, `N8N_BLOCK_ENV_ACCESS_IN_NODE` still true, workflow A inactive, wrong URL |
| Every POST gets 403 | wrong `META_APP_SECRET`; `crypto` not allowed (execution shows `verify_error`); proxy altered the body |
| 200 but no reply | `Process Event` still has the placeholder id; D inactive/not configured; look at `SELECT * FROM bakery.notification_outbox ORDER BY id DESC LIMIT 20;` for `last_error_code` |
| Outbox `AUTH` | expired/invalid access token → fix credential, then requeue |
| `131047` / BLOCKED_WINDOW | 24 h window closed and no template configured |
| `CONFIG` dead letters | `WHATSAPP_API_VERSION` / `META_PHONE_NUMBER_ID` missing or malformed |
| Events stuck PROCESSING | C failed; E replays after 2 min; after 5 attempts they go DEAD |
| "could not read that time" | the parser expects forms like "tomorrow 5 PM", "28 Oct 11:30 AM", "17:30" |

## 13. Operational notes

- `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` exposes environment values to workflow editors; limit editor access.
- A customer message is parsed as one intent at a time. For example, a cake request and delivery time are handled in separate turns.
- Time parsing uses common date and time formats; the confirmation summary shows the resolved local time.
- Outbound delivery is at-least-once. A retry can produce a duplicate message but does not recreate an order.
- Cart expiry is handled by the maintenance workflow and the next customer message. Stock is checked at confirmation.
- The staff status API uses a shared header key over TLS; restrict access to the webhook endpoint.
- Meta API versions, error codes, and template rules change; check `classify_send.js` against current documentation when configuring the integration.
