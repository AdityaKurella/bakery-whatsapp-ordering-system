# Bakery WhatsApp Ordering System — n8n 2.22.6 + PostgreSQL (test-mode first)

**Status: a design plus code that passed static checks and Code-node unit tests. It has NOT been imported into n8n 2.22.6 and the SQL has NOT been run on PostgreSQL by the author.** Section 10 lists exactly what was and was not verified. Do not use for real customers until you have completed Section 12.

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
- **Prices:** integer minor units (`bigint`), only from `product_variants`. Discounts: column exists, feature **not implemented**. Tax: optional basis-points setting.
- **Targeted n8n version 2.22.6.** I used node versions that exist in 1.x and are retained in 2.x: Webhook 2, Code 2, IF 2.2, Respond to Webhook 1.4, Postgres 2.5, HTTP Request 4.2, Execute Workflow 1.2, Execute Workflow Trigger 1.1, Schedule Trigger 1.2, Error Trigger 1, Manual Trigger 1, Sticky Note 1. **I could not inspect 2.22.6 schemas** (no network in the build sandbox). If a node shows a warning after import, open it and re-select the operation; this is the first thing to check.
- **One Webhook node vs two:** newer Webhook versions can accept several methods, but I used two workflows (A = GET, B = POST) on the *same path*. n8n distinguishes webhooks by method + path, so one Meta callback URL serves both. This was not tested on 2.22.6.

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
| `tests/sql_smoke_test.sql` | 54 expectations on the DB engine, rolled back at the end (not yet executed against PostgreSQL) |
| `tests/payloads/*.json` | Meta-format sample payloads (dummy ids/numbers) |

## 3. Prerequisites you must confirm
1. **PostgreSQL 13+** reachable from n8n (status unconfirmed). Easiest for local testing: add a `postgres:16` container on the same Docker network as n8n; from n8n use host `postgres` (not `localhost`).
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
**Run the smoke test and fix anything it reports before touching n8n** — the SQL was never executed by the author, so expect to correct small syntax/semantic mistakes. Then set the bakery notification target (digits only, with country code; the number must be allowed on your test setup):
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
7. **Activation sequence:** F (no trigger to activate besides being selected as error workflow) → D → E → B → A. C is only called by others and need not be active. Keep "production" (real business number) disabled until §12 is complete. For the Meta test number you do need B and A active, because Meta can only call the production URL.

## 8. Webhook signature verification (what is and isn't guaranteed)
- Workflow B turns on the Webhook node's **Raw Body** option, reads the raw bytes, computes `HMAC-SHA256(META_APP_SECRET, rawBody)`, compares timing-safely with `X-Hub-Signature-256`, and only then parses that same buffer. It **fails closed**: no secret, no raw body, or `crypto` not allowed → 403.
- Assumption to verify on 2.22.6: the raw body arrives as a binary property of the first item (the code uses whichever binary key exists). Test with `tools/sign_and_post.py` (T-02/T-03 below). If a *valid* signature is rejected, open the execution of *Verify Signature* and read `reason`.
- **Stricter alternative** (no secrets in n8n): terminate TLS in nginx/Caddy/Cloudflare Worker, verify the signature there, and forward only verified requests to n8n; then remove the check in B. I have not provided that gateway config.
- Gateway rate limiting is recommended (e.g. nginx `limit_req`) in addition to the per-customer limit inside the database.

## 9. Meta Developer setup
1. developers.facebook.com → your app → WhatsApp → API Setup: copy **Phone number ID**, add your phone as a recipient, generate a (temporary) access token → put it in the `WhatsApp Cloud Bearer` credential.
2. WhatsApp → Configuration → Webhook: Callback URL `https://YOUR-HOST/webhook/whatsapp-bakery`, Verify token = `META_VERIFY_TOKEN`. Click *Verify and save* (hits Workflow A). Subscribe to the **messages** field.
3. Send "hi" from your phone to the test number. Within seconds you should get the welcome message.
4. The bakery notification recipient must also be allowed on the test number. Outside the 24 h window only approved templates can be sent: the seed uses Meta's built-in `hello_world` template (no parameters) so notifications work on a test number; replace with your own approved template and set `params` (`order_ref`, `summary`, `total`) for real use. To receive free-form bakery alerts, message the bot once from the staff phone (this opens that phone's 24 h window).
5. Test URLs (`/webhook-test/...`) only work while the editor is "listening" on one workflow; because Meta needs both GET and POST, use the production URLs on the test number, and use `sign_and_post.py` against `/webhook-test/` for dry runs.

## 10. Validation performed (and not performed)
| Done | How |
|---|---|
| ✅ All six JSON files parse; unique node ids/names; every connection resolves; every node reachable from a trigger; all `inactive`; no embedded credential ids or secret-like strings | `python3 tools/validate.py` |
| ✅ JavaScript syntax of all 13 Code-node sources | `node --check` inside `validate.py` |
| ✅ Postgres node `$n` placeholders match the number of `queryReplacement` values in every query | `validate.py` |
| ✅ 179 behaviour assertions on parser, signature check, normaliser, renderers (WhatsApp length limits), outbox renderer, response classifier, AI validator, error redaction | `node tests/unit_test.js` |
| ✅ Every SQL function called by a workflow exists; `$fn$` delimiters balanced | script |
| ❌ **Import into n8n 2.22.6** | not possible in the build sandbox |
| ❌ **Execution of any workflow** | not done |
| ❌ **Execution of any SQL** | no PostgreSQL available; use `tests/sql_smoke_test.sql` |
| ❌ Calls to the real Meta/Anthropic APIs | not done; request shapes follow documented formats from memory — confirm against Meta's current docs |

Manual validation steps: (1) run `tools/validate.py`; (2) run the SQL smoke test; (3) import into n8n; open every node and confirm no "node version/parameter" warnings; (4) run T-01…T-20.

## 11. Acceptance test matrix
`DUMMY` = no Meta credentials needed (use `tools/sign_and_post.py` or SQL). `META` = needs the test number.
Send payload tests to `https://HOST/webhook/whatsapp-bakery` (or `/webhook-test/…`). You need `META_APP_SECRET` for signing; the DB must be set up.

| # | Test | How | Expected | Needs |
|---|---|---|---|---|
| T-01 | Valid text message | `sign_and_post.py URL tests/payloads/01_text_message.json --secret S` | HTTP 200 `OK`; row in `webhook_event_log` (DONE); outbox reply row created (SENT with Meta, else DEAD/AUTH without a real token) | DUMMY (send needs META) |
| T-02 | Meta GET verification | `sign_and_post.py 'URL?hub.mode=subscribe&hub.verify_token=T&hub.challenge=1234' --get` | 200, body `1234`, text/plain | DUMMY |
| T-03 | Invalid verification token | same with wrong token | 403 `Forbidden`, no echo of token/challenge | DUMMY |
| T-04 | Invalid signature | `--bad-signature`, or wrong secret | 403; no row stored | DUMMY |
| T-05 | Delivery-status event | payload `02_status_delivered.json` | 200; stored as `STATUS` already DONE; **no** customer/order created; matching outbox row's `delivery_status` updated if the id exists | DUMMY |
| T-06 | Duplicate inbound message | send `01_text_message.json` twice | both 200; one event row; one reply | DUMMY |
| T-07 | Unknown product | text "add zzz widget" | "I could not find that item" + menu button; no cart row | DUMMY (reply send: META) |
| T-08 | Bad quantities | "add -2 chocolate pastry", "add 0 …", "add 1.5 …", "add 5000 …" | quantity message each time, cart unchanged (SQL smoke test covers it deterministically) | DUMMY |
| T-09 | Unavailable product | add `BRD-SEAS-01` | "not available" | DUMMY |
| T-10 | Custom cake, missing options | "I want a birthday cake" | asks size → flavor → egg → frosting → message in turn; nothing in cart until complete; invalid flavor is re-asked | DUMMY |
| T-11 | Edit cart | add, "change my cake to 2 kg", "remove one pastry", "remove item 2", "clear cart" | totals recomputed from DB prices each time | DUMMY |
| T-12 | Confirm twice | tap Confirm twice / type "confirm" twice | exactly one `orders` row; second answer "already confirmed" | DUMMY |
| T-13 | Database outage during confirmation | stop Postgres mid-test, then confirm | B returns 503 if intake fails (Meta redelivers); if C fails, event stays PROCESSING → E replays after ≥2 min; **no partial order** (transaction) and F alerts | DUMMY (needs Docker control) |
| T-14 | Notification failure after order | make the WhatsApp credential invalid, confirm an order | order exists; outbox `DEAD/AUTH` (not retried); alert; after fixing credential `SELECT bakery.fn_requeue_dead_outbox('AUTH');` sends it; still one order | DUMMY→META |
| T-15 | WhatsApp 429 / 5xx | cannot be forced against Meta; simulate with `bakery.fn_outbox_record(id,'RETRY',…)` and by pointing `url` at a mock server | row returns to PENDING with growing `next_attempt_at` (30 s·2ⁿ ± jitter), dead after `outbox_max_attempts` | DUMMY (mock) |
| T-16 | AI provider outage | set `ai_enabled=true` with a bad key/model, send "hmm what do you suggest" | falls back to the "didn't catch that" menu; no error to customer | DUMMY |
| T-17 | Expired cart | `UPDATE bakery.carts SET expires_at = now()-interval '1 min' WHERE status='OPEN';` wait for E (or run it) | cart `EXPIRED`, session reset; next message says cart expired | DUMMY |
| T-18 | Unauthorized status lookup | customer B asks status/cancel with customer A's reference | "could not find that order" (identical to a nonexistent ref) | DUMMY (SQL smoke test) |
| T-19 | Cancel after fulfilment started | staff API `status: PREPARING`, then customer "cancel my order" | refused with "contact the bakery" | DUMMY |
| T-20 | Invalid date / closed / too soon | "tomorrow 11 PM", "yesterday 5 PM", custom cake "in 2 hours" | specific message (CLOSED / PAST / TOO_SOON); time not stored | DUMMY |

Also: `05_unsupported_image.json` → "I can only read text and buttons"; `06_wrong_phone_number_id.json` → ignored (0 events); `07_malicious_text.json` → must not confirm anything, change a price, or send to another number (it is treated as text; unrecognised → menu).

Staff API example:
```
curl -X POST https://HOST/webhook/bakery-order-status -H "X-Bakery-Key: $KEY" -H 'Content-Type: application/json' \
  -d '{"order_ref":"BK-261024-00001-A3F","status":"PREPARING","actor":"Asha"}'
curl ... -d '{"order_ref":"BK-...","payment_status":"PAID","actor":"Asha","note":"UPI ref checked manually"}'
```
Payment is **never** set from a customer message; only this endpoint (or SQL) can mark `PAID`.

## 12. Deployment, operations, and production-readiness checklist
**Backup/restore:** `pg_dump -Fc -d bakery -f bakery_$(date +%F).dump` daily (and before any migration). Restore test (do this monthly): `createdb bakery_restore && pg_restore -d bakery_restore bakery_….dump`, then run a few `SELECT count(*)` checks.
**Recovery runbook**
- Dead letters: run workflow E's manual branch, or `SELECT * FROM bakery.v_dead_letters;`
- Replay a dead inbound event: `SELECT bakery.fn_replay_dead_event(<id>);` — Replay failed notifications: `SELECT bakery.fn_requeue_outbox(<id>);` or by cause `SELECT bakery.fn_requeue_dead_outbox('AUTH');` (`CONFIG`, `NOTIFY_NOT_CONFIGURED`, …)
- Order without a bakery notification: find `notification_outbox` rows for its `order_id` with status DEAD/BLOCKED_WINDOW and requeue; the order itself is never recreated.
- Retention (defaults): message text wiped after 7 days, events deleted after 14, idempotency keys kept ≥30 days, sent outbox 30 days, error log 30 days. Confirmed orders are never deleted by maintenance. Erasure helper: `bakery.fn_erase_customer('<wa_id>')` (anonymises orders rather than deleting them — review with your legal adviser).
**Cost drivers (no prices quoted):** WhatsApp conversation/message charges per Meta's current rate card, hosting for n8n + PostgreSQL + public HTTPS, LLM tokens if enabled, storage for backups.
**Rollback plan:** deactivate B (Meta then retries for a while; events resume when re-activated), restore the previous workflow JSONs and DB dump if needed.

**Production-readiness checklist** (all must be ticked; none are done by this package)
- [ ] SQL smoke test passes on your PostgreSQL; schema reviewed by someone who knows PostgreSQL
- [ ] Workflows imported on 2.22.6 with zero node warnings; T-01…T-20 executed and recorded
- [ ] Signature check proven with a valid and an invalid signature on the **public** URL
- [ ] Real (not demo) catalogue, prices, hours, timezone, delivery/cancel rules loaded; seed demo products removed
- [ ] Permanent access token (system user) instead of the 24 h temporary token; approved message templates; business verification / production approval from Meta
- [ ] HTTPS reverse proxy, firewall (only 443 public), n8n editor not publicly exposed, strong credentials, `bakery_app` DB role
- [ ] `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` risk accepted or gateway verification adopted (§8)
- [ ] Execution pruning on; backups scheduled and a restore tested; alert channel verified (force an error and see F alert)
- [ ] Privacy notice / consent text for storing names, numbers and addresses; retention values agreed
- [ ] A named person monitors the dead-letter list and alerts

## 13. Troubleshooting
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

## 14. Known limitations and unresolved risks (read before trusting this)
1. **Nothing was executed against n8n 2.22.6 or PostgreSQL.** Expect fixes. The highest-risk spots: raw-body binary handling in B; `queryReplacement` array expressions on Postgres node 2.5; `FOR UPDATE OF p` with an aggregate subquery in `_confirm_order`; Execute Workflow parameter shape; pairing of HTTP results with outbox rows in D (`$('Can Send?').all(0)`).
2. `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` exposes env secrets to workflow editors.
3. **Numbered text-menu fallbacks are not implemented**; the fallback for rejected interactive messages is plain text listing the *keywords* to type (e.g. "Reply *confirm* | *edit*").
4. `REVIEWING_ORDER` is defined in the state constraint but **not persisted** (the summary immediately moves the session to `AWAITING_CONFIRMATION`).
5. One intent per message: "order a cake and deliver tomorrow 5 PM" adds the cake; the time/delivery are asked next, not parsed from the same sentence.
6. Time parsing is heuristic: day-first dates (dd/mm), bare "at 5" means 5 PM for hours 1–7. The confirmation summary always shows the resolved local time so the customer can catch mistakes.
7. Out-of-order *inbound* messages are serialised per customer and stale confirm buttons are rejected, but free-text messages are not re-ordered by WhatsApp timestamp.
8. Outbound delivery is at-least-once; ordering of multiple outbound messages is by outbox id on first attempt, not guaranteed across retries.
9. Discounts, online payments, order editing after confirmation, multi-language strings (English only; renderers are separated so languages can be added), WhatsApp Flows, delivery-area validation, and a staff-facing WhatsApp command interface are **not implemented**.
10. Cart expiry lazily happens on next message and in E; stock reservation happens only at confirmation, so two customers can both hold the last tracked item in their carts (the second confirmation is refused).
11. The staff status API is protected only by a shared header key and TLS; add IP allow-listing for real use.
12. Meta API versions, error codes (131047, 190, 131026 …) and template rules change; review `classify_send.js` against current docs.

