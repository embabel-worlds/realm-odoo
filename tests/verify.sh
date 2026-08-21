#!/bin/sh
# relentless-testing harness for realm-odoo — L0 ground truth from Odoo itself, then exact
# reconciliation of every Embabel layer against it. Exits nonzero on ANY drift.
#
#   ODOO=http://127.0.0.1:8069 ODOO_KEY=... APPLIANCE=http://127.0.0.1:4342 AUTH=user:pass \
#     sh tests/verify.sh
set -e
ODOO="${ODOO:-http://127.0.0.1:8069}"
APPLIANCE="${APPLIANCE:-http://127.0.0.1:4342}"
: "${ODOO_KEY:?set ODOO_KEY}"; : "${AUTH:?set AUTH (user:pass)}"

fail=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "  ok   $1 = $2"
  else echo "  FAIL $1: expected $2, got $3"; fail=1; fi
}
py() { python3 -c "$1"; }

echo "== L0: ground truth, from Odoo directly =="
CUSTOMERS=$(curl -s -X POST "$ODOO/json/2/res.partner/search_count" -H "Authorization: Bearer $ODOO_KEY" \
  -H 'Content-Type: application/json' -d '{"domain":[["customer_rank",">",0]]}')
TRUTH=$(curl -s -X POST "$ODOO/json/2/account.move/search_read" -H "Authorization: Bearer $ODOO_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"domain":[["move_type","=","out_invoice"],["state","=","posted"],["payment_state","in",["not_paid","partial"]]],"fields":["partner_id","amount_residual"],"load":"","limit":500}')
TOP_OWED=$(echo "$TRUTH" | py "
import json,sys,collections
t=collections.defaultdict(float)
for r in json.load(sys.stdin): t[r['partner_id']]+=r['amount_residual']
pid,amt=max(t.items(), key=lambda kv: kv[1]); print(f'{pid}:{amt:.2f}')")
echo "  customers=$CUSTOMERS  top-debtor(partner:total)=$TOP_OWED"

echo "== L1: traversal reconciles =="
KG=$(curl -s -u "$AUTH" -X POST "$APPLIANCE/api/v1/admin/kg/execute" -H 'Content-Type: application/json' \
  -d '{"cypher":"MATCH (b:OdooBook)-[:HAS_CUSTOMER]->(c:OdooCustomer) RETURN count(DISTINCT c) AS n"}')
check "kg customer count" "$CUSTOMERS" "$(echo "$KG" | py 'import json,sys;print(json.load(sys.stdin)["rows"][0]["n"])')"

echo "== L2: the view, id-deduped, reconciles to the cent =="
VIEW=$(curl -s -u "$AUTH" -X POST "$APPLIANCE/api/v1/views/OdooPipelineReceivables/invoke" \
  -H 'Content-Type: application/json' -d '{"args":{"stage":"Proposition"}}')
VIEW_TOP=$(echo "$VIEW" | py "
import json,sys
rows=json.load(sys.stdin).get('data') or []
seen={}
for r in rows:
    if r.get('invoiceId') is not None: seen[r['invoiceId']]=(int(r['customerId']),r['owed'])
tot={}
for cid,owed in seen.values(): tot[cid]=tot.get(cid,0)+owed
pid,amt=max(tot.items(), key=lambda kv: kv[1]); print(f'{pid}:{amt:.2f}')")
check "view top debtor (vs L0)" "$TOP_OWED" "$VIEW_TOP"

echo "== L3: the natural-language battery, figures not just rows =="
EXP_AMT=${TOP_OWED#*:}
# Money questions run 3x: generation is stochastic; a view-routed answer is stable, and any
# drift on any run is a failure.
for Q in "How many customers do we have" "Which customers owe us most money" "Which customers owe us most money" "Which customers owe us most money" "which is our most valuable customer"; do
  A=$(curl -s -u "$AUTH" -X POST "$APPLIANCE/api/v1/admin/kg/ask" -H 'Content-Type: application/json' \
    -d "{\"question\":\"$Q\"}")
  GOT=$(echo "$A" | py "
import json,sys
d=json.loads(sys.stdin.read(), strict=False); rows=d.get('rows') or []
if not rows: print('NO-ROWS'); raise SystemExit
r=rows[0]
nums=[v for v in r.values() if isinstance(v,(int,float))]
print(f'{max(nums):.2f}' if nums else 'NO-NUMBER')")
  case "$Q" in
    "How many customers"*) check "NL: $Q" "$CUSTOMERS.00" "$GOT" ;;
    *) check "NL: $Q (top figure)" "$EXP_AMT" "$GOT" ;;
  esac
done

echo "== L5: the app's own calls =="
for a in whole-customer whole-customer.css whole-customer.js; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" "$APPLIANCE/api/v1/apps/$a")
  check "app asset $a" "200" "$code"
done

echo "== L3b: the battery (tests/questions.yml) =="
DIR="$(dirname "$0")"
python3 - "$DIR/questions.yml" "$APPLIANCE" "$AUTH" <<'PYEOF' || fail=1
import json, sys, subprocess, yaml

qfile, base, auth = sys.argv[1], sys.argv[2], sys.argv[3]
battery = yaml.safe_load(open(qfile))
def curl(path, body):
    out = subprocess.run(["curl", "-s", "-u", auth, "-X", "POST", base + path,
                          "-H", "Content-Type: application/json", "-d", json.dumps(body)],
                         capture_output=True, text=True).stdout
    return json.loads(out, strict=False)

def top_figure(rows, column=None):
    if not rows: return None
    r = rows[0]
    if column and column in r: return round(float(r[column]), 2)
    # Ids travel with rows by convention (customerId, leadId, ...) — never mistake one
    # for the figure being asked about.
    nums = [v for k, v in r.items() if isinstance(v, (int, float)) and not k.endswith('Id')]
    return round(max(nums), 2) if nums else None

bad = 0
for case in battery:
    q, exp = case["question"], case.get("expect", {"nonEmpty": True})
    a = curl("/api/v1/admin/kg/ask", {"question": q})
    rows = a.get("rows") or []
    if "matchesView" in exp:
        mv = exp["matchesView"]
        v = curl("/api/v1/views/%s/invoke" % mv["name"], {"args": mv.get("args", {})})
        vrows = v.get("data") or []
        want, got = top_figure(vrows, mv.get("column")), top_figure(rows)
        ok = want is not None and got == want
        print(("  ok   " if ok else "  FAIL ") + q + " -> " + str(got) + (" (view: %s)" % want))
        if not ok: bad += 1
    else:
        need = exp.get("minRows", 1 if exp.get("nonEmpty") else 0)
        ok = len(rows) >= need
        print(("  ok   " if ok else "  FAIL ") + q + " -> " + str(len(rows)) + " rows")
        if not ok:
            bad += 1
            print("       cypher: " + " ".join((a.get("cypher") or "").split())[:180])
sys.exit(1 if bad else 0)
PYEOF

[ "$fail" = 0 ] && echo "ALL CHECKS PASS" || { echo "DRIFT DETECTED"; exit 1; }
