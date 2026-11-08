#!/usr/bin/env python3
"""Send a signed (or deliberately badly signed) Meta-style webhook to n8n. Stdlib only. No Meta credentials needed.
  python3 tools/sign_and_post.py URL tests/payloads/01_text_message.json --secret YOUR_APP_SECRET            # valid signature
  python3 tools/sign_and_post.py URL tests/payloads/01_text_message.json --secret x --bad-signature          # must be rejected (403)
  python3 tools/sign_and_post.py URL tests/payloads/01_text_message.json --secret YOUR_APP_SECRET --phone-id 123  # rewrite metadata.phone_number_id
  python3 tools/sign_and_post.py 'URL?hub.mode=subscribe&hub.verify_token=T&hub.challenge=1234' --get"""
import argparse, hashlib, hmac, json, sys, urllib.request, urllib.error
ap = argparse.ArgumentParser(); ap.add_argument("url"); ap.add_argument("payload", nargs="?"); ap.add_argument("--secret"); ap.add_argument("--bad-signature", action="store_true")
ap.add_argument("--get", action="store_true"); ap.add_argument("--phone-id")
a = ap.parse_args()
try:
    if a.get:
        req = urllib.request.Request(a.url, method="GET")
    else:
        body = open(a.payload, "rb").read()
        if a.phone_id:
            d = json.loads(body)
            for e in d["entry"]:
                for c in e["changes"]: c["value"]["metadata"]["phone_number_id"] = a.phone_id
            body = json.dumps(d).encode()
        sig = hmac.new((a.secret or "").encode(), body, hashlib.sha256).hexdigest()
        if a.bad_signature: sig = "0" * 64
        req = urllib.request.Request(a.url, data=body, method="POST", headers={"Content-Type": "application/json", "X-Hub-Signature-256": "sha256=" + sig})
    with urllib.request.urlopen(req, timeout=20) as r: print(r.status, r.read().decode()[:300])
except urllib.error.HTTPError as e: print(e.code, e.read().decode()[:300])
