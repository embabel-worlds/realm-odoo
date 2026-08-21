#!/usr/bin/env bash
# Seed the demo records in records.yml into an Odoo instance — through the JSON-2
# API, as a normal authenticated user, never the database. Refuses to run without
# an explicit --yes, because the difference between a demo Odoo and a real one is
# one URL. Idempotent: partners are looked up by name, invoices by SEED- ref,
# opportunities by name, and anything already present is left alone.
#
#   ODOO_API_KEY=... ./seed.sh --yes [--url http://127.0.0.1:8069]
#   ODOO_API_KEY=... ./seed.sh --remove --yes     # delete what a previous run created
set -euo pipefail
cd "$(dirname "$0")"

URL="${ODOO_URL:-http://127.0.0.1:8069}"; CONFIRM=no; REMOVE=no
while [ $# -gt 0 ]; do case "$1" in
  --yes) CONFIRM=yes;; --remove) REMOVE=yes;; --url) URL="$2"; shift;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; shift; done

[ -n "${ODOO_API_KEY:-}" ] || { echo "ODOO_API_KEY is not set" >&2; exit 2; }
if [ "$CONFIRM" != yes ]; then
  echo "This would write demo records into $URL — a system you must consider disposable." >&2
  echo "Re-run with --yes to proceed." >&2
  exit 2
fi

URL="$URL" REMOVE="$REMOVE" python3 - <<'PY'
import json, os, sys, urllib.request
import yaml

URL, KEY, REMOVE = os.environ["URL"].rstrip("/"), os.environ["ODOO_API_KEY"], os.environ["REMOVE"] == "yes"

def call(model, method, payload):
    req = urllib.request.Request(
        f"{URL}/json/2/{model}/{method}",
        data=json.dumps(payload).encode(),
        headers={"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req) as r:
        return json.load(r)

def one(model, domain, fields=("id",)):
    rows = call(model, "search_read", {"domain": domain, "fields": list(fields), "load": "", "limit": 1})
    return rows[0] if rows else None

records = yaml.safe_load(open("records.yml"))

if REMOVE:
    # Invoices must leave posted state before they can be deleted; leads and any
    # partner with no remaining documents unlink directly.
    for inv in call("account.move", "search_read", {"domain": [["ref", "like", "SEED-%"]], "fields": ["id", "state"], "load": ""}):
        if inv["state"] == "posted":
            call("account.move", "button_draft", {"ids": [inv["id"]]})
        call("account.move", "unlink", {"ids": [inv["id"]]})
        print(f"removed invoice {inv['id']}")
    for lead in call("crm.lead", "search_read", {"domain": [["name", "like", "SEED %"]], "fields": ["id"], "load": ""}):
        call("crm.lead", "unlink", {"ids": [lead["id"]]})
        print(f"removed opportunity {lead['id']}")
    for c in records["customers"]:
        p = one("res.partner", [["name", "=", c["name"]]])
        if p:
            try:
                call("res.partner", "unlink", {"ids": [p["id"]]})
                print(f"removed partner {c['name']}")
            except Exception:
                print(f"kept partner {c['name']} (still referenced)")
    sys.exit(0)

stages = {s["name"]: s["id"] for s in call("crm.stage", "search_read", {"domain": [], "fields": ["id", "name"], "load": ""})}

for c in records["customers"]:
    p = one("res.partner", [["name", "=", c["name"]]])
    if p:
        pid = p["id"]; print(f"partner {c['name']} already present (id {pid})")
    else:
        pid = call("res.partner", "create", {"vals_list": [{"name": c["name"], "website": c["website"], "is_company": True, "customer_rank": 1}]})[0]
        print(f"created partner {c['name']} (id {pid})")
    for inv in c.get("invoices", []):
        if one("account.move", [["ref", "=", inv["ref"]]]):
            print(f"  invoice {inv['ref']} already present"); continue
        mid = call("account.move", "create", {"vals_list": [{
            "move_type": "out_invoice", "partner_id": pid, "ref": inv["ref"],
            "invoice_line_ids": [[0, 0, {"name": inv["description"], "quantity": 1, "price_unit": inv["amount"]}]],
        }]})[0]
        call("account.move", "action_post", {"ids": [mid]})
        print(f"  created+posted invoice {inv['ref']} ({inv['amount']})")
    for opp in c.get("opportunities", []):
        if one("crm.lead", [["name", "=", opp["name"]]]):
            print(f"  opportunity '{opp['name']}' already present"); continue
        call("crm.lead", "create", {"vals_list": [{
            "name": opp["name"], "partner_id": pid, "type": "opportunity",
            "expected_revenue": opp["expected_revenue"], "probability": opp["probability"],
            "stage_id": stages[opp["stage"]],
        }]})
        print(f"  created opportunity '{opp['name']}'")
PY
