#!/bin/sh
# relentless-testing harness for realm-odoo — L0 ground truth from Odoo itself, then exact
# reconciliation of every Embabel layer against it. Exits nonzero on ANY drift.
#
#   ODOO=http://127.0.0.1:8069 ODOO_KEY=... APPLIANCE=http://127.0.0.1:4342 AUTH=user:pass \
#     sh tests/verify.sh
set -e
# Either AUTH=user:pass or TOKEN=<appliance API key>. Both go to curl through a config file, so
# neither appears on a command line where `ps` would show it.
AUTHCFG=$(mktemp); trap 'rm -f "$AUTHCFG"' EXIT
if [ -n "${TOKEN:-}" ]; then printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" > "$AUTHCFG"
else printf 'user = "%s"\n' "${AUTH:?set AUTH (user:pass) or TOKEN}" > "$AUTHCFG"; fi
ODOO="${ODOO:-http://127.0.0.1:8069}"
APPLIANCE="${APPLIANCE:-http://127.0.0.1:4342}"
: "${ODOO_KEY:?set ODOO_KEY}"; 
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
  -d '{"domain":[["move_type","=","out_invoice"],["state","=","posted"],["payment_state","in",["not_paid","partial"]]],"fields":["partner_id","amount_residual"],"load":""}')
TOP_OWED=$(echo "$TRUTH" | py "
import json,sys,collections
t=collections.defaultdict(float)
for r in json.load(sys.stdin): t[r['partner_id']]+=r['amount_residual']
# A book with nothing owed is a real book: the honest top debtor is none, not a crash.
if not t: print('none'); raise SystemExit
pid,amt=max(t.items(), key=lambda kv: kv[1]); print(f'{pid}:{amt:.2f}')")
# WHICH BOOK THIS IS. Some checks are about the demo book seed/ loads — its named companies, its
# chatter arcs, its meetings — and some need Odoo to hold receivables at all. A book without them is
# a real book (a world whose invoices live in a billing system is the usual one), so those checks
# say SKIP and why, rather than failing against a book they were never about.
SEEDED=$(ODOO="$ODOO" ODOO_KEY="$ODOO_KEY" py "
import json, os, urllib.request
def count(model, domain):
    req = urllib.request.Request(os.environ['ODOO'] + '/json/2/' + model + '/search_count', data=json.dumps({'domain': domain}).encode(),
                                 headers={'Authorization': 'Bearer ' + os.environ['ODOO_KEY'], 'Content-Type': 'application/json'})
    with urllib.request.urlopen(req) as r: return json.load(r)
seeded = count('res.partner', [['name', '=', 'Qantas']]) > 0 and \
         count('crm.lead', [['name', '=', 'SEED Team workflow rollout'], '|', ['active', '=', True], ['active', '=', False]]) > 0
print(1 if seeded else 0)")
RECEIVABLES=$([ "$TOP_OWED" = none ] && echo 0 || echo 1)
echo "  customers=$CUSTOMERS  top-debtor(partner:total)=$TOP_OWED  demo-seed=$SEEDED  receivables=$RECEIVABLES"

echo "== L1: traversal reconciles =="
KG=$(curl -s -K "$AUTHCFG" -X POST "$APPLIANCE/api/v1/admin/kg/execute" -H 'Content-Type: application/json' \
  -d '{"cypher":"MATCH (b:OdooBook)-[:HAS_CUSTOMER]->(c:OdooCustomer) RETURN count(DISTINCT c) AS n"}')
check "kg customer count" "$CUSTOMERS" "$(echo "$KG" | py 'import json,sys;print(json.load(sys.stdin)["rows"][0]["n"])')"

echo "== L1b: the company hierarchy reconciles =="
# Odoo's own answer: the company with the most companies filed under it, and their ids. The
# realm must reach exactly those through HAS_SUBSIDIARY, every one of them must lead back up
# through SUBSIDIARY_OF, and no person may appear among them. A book with no company hierarchy
# is a real book: the check says so and moves on.
GROUP=$(curl -s -X POST "$ODOO/json/2/res.partner/search_read" -H "Authorization: Bearer $ODOO_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"domain":[["is_company","=",true],["parent_id","!=",false]],"fields":["parent_id"],"load":""}' | py "
import json,sys,collections
kids=collections.defaultdict(list)
for r in json.load(sys.stdin): kids[r['parent_id']].append(r['id'])
if not kids: print('none'); raise SystemExit
pid,ids=max(kids.items(), key=lambda kv: (len(kv[1]), -kv[0])); print(f'{pid}:{\",\".join(str(i) for i in sorted(ids))}')")
if [ "$GROUP" = "none" ]; then echo "  skip no company in this book has a parent company"
else
  PARENT=${GROUP%%:*}
  DOWN=$(curl -s -K "$AUTHCFG" -X POST "$APPLIANCE/api/v1/admin/kg/execute" -H 'Content-Type: application/json' \
    -d "{\"cypher\":\"MATCH (b:OdooBook)-[:HAS_COMPANY]->(c:OdooCustomer) WHERE c.id = '$PARENT' MATCH (c)-[:HAS_SUBSIDIARY]->(s:OdooCustomer) OPTIONAL MATCH (s)-[:SUBSIDIARY_OF]->(up:OdooCustomer) RETURN s.id AS id, up.id AS up\"}")
  check "subsidiaries of $PARENT (vs L0)" "$GROUP" "$PARENT:$(echo "$DOWN" | py 'import json,sys;print(",".join(sorted({str(r["id"]) for r in json.load(sys.stdin)["rows"]}, key=int)))')"
  check "each leads back up to $PARENT" "$PARENT" "$(echo "$DOWN" | py 'import json,sys;print(",".join(sorted({str(r["up"]) for r in json.load(sys.stdin)["rows"]})) or "none")')"
fi

echo "== L2: the view, id-deduped, reconciles to the cent =="
VIEW=$(curl -s -K "$AUTHCFG" -X POST "$APPLIANCE/api/v1/views/OdooPipelineReceivables/invoke" \
  -H 'Content-Type: application/json' -d '{"args":{"stage":"Proposition"}}')
VIEW_TOP=$(echo "$VIEW" | py "
import json,sys
rows=json.load(sys.stdin).get('data') or []
seen={}
for r in rows:
    if r.get('invoiceId') is not None: seen[r['invoiceId']]=(int(r['customerId']),r['owed'])
tot={}
for cid,owed in seen.values(): tot[cid]=tot.get(cid,0)+owed
if not tot: print('none'); raise SystemExit
pid,amt=max(tot.items(), key=lambda kv: kv[1]); print(f'{pid}:{amt:.2f}')")
check "view top debtor (vs L0)" "$TOP_OWED" "$VIEW_TOP"

echo "== L2b: what Odoo filters, and what a question costs =="
# Every view below filters at the SOURCE (producers/odoo.yml, `pushdown:`), so each is checked
# twice: its figure against Odoo asked directly, and its `metrics.externalCalls` against a
# ceiling that does not grow with the book. A cache can only lower a call count, so the
# ceilings hold warm or cold; a pushdown that silently stopped narrowing shows as a count past
# its ceiling, or — for a single company — as a figure that is the book's rather than its own.
ODOO="$ODOO" ODOO_KEY="$ODOO_KEY" APPLIANCE="$APPLIANCE" AUTHCFG="$AUTHCFG" python3 - <<'PYEOF' || fail=1
import json, os, subprocess, urllib.request
odoo, key = os.environ['ODOO'], os.environ['ODOO_KEY']
base, auth = os.environ['APPLIANCE'], os.environ['AUTHCFG']

def ask_odoo(model, method, body):
    req = urllib.request.Request(f"{odoo}/json/2/{model}/{method}", data=json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req) as resp:
        return json.load(resp)

def view(name, args):
    out = subprocess.run(["curl", "-s", "-K", auth, "-X", "POST", f"{base}/api/v1/views/{name}/invoke",
                          "-H", "Content-Type: application/json", "-d", json.dumps({"args": args})],
                         capture_output=True, text=True).stdout
    d = json.loads(out, strict=False)
    return d, d.get("data") or [], (d.get("metrics") or {}).get("externalCalls")

bad = 0
def check(name, ok, detail=""):
    global bad
    print(("  ok   " if ok else "  FAIL ") + name + (f" ({detail})" if detail and not ok else ""))
    if not ok: bad += 1
def within(name, calls, ceiling):
    check(f"{name}: {calls} source call(s), ceiling {ceiling}", calls is not None and calls <= ceiling, f"got {calls}")

money = lambda x: round(float(x or 0), 2)
UNPAID = [["move_type", "=", "out_invoice"], ["state", "=", "posted"], ["payment_state", "in", ["not_paid", "partial"]]]

# ONE COMPANY, O(1). The company that owes most, read by its exact name: one call for the company,
# one for its invoices, one for its deals — however many companies the book holds.
inv = ask_odoo("account.move", "search_read", {"domain": UNPAID, "fields": ["partner_id", "amount_residual"], "load": ""})
owed = {}
for r in inv: owed[r["partner_id"]] = owed.get(r["partner_id"], 0) + r["amount_residual"]
companies = ask_odoo("res.partner", "search_read", {"domain": [["id", "in", list(owed)], ["is_company", "=", True]],
                                                     "fields": ["name"], "load": ""}) if owed else []
if not companies:
    print("  skip no company owes anything in this book")
else:
    top = max(companies, key=lambda c: (owed[c["id"]], -c["id"]))
    same_name = ask_odoo("res.partner", "search_count", {"domain": [["name", "=", top["name"]], ["is_company", "=", True]]})
    d, rows, calls = view("OdooAccountSnapshot", {"company": top["name"]})
    check("snapshot answered", d.get("status") == "SUCCEEDED", str(d)[:200])
    check(f"snapshot of '{top['name']}' is that company alone ({same_name} of that exact name in Odoo)",
          len(rows) == same_name and all(str(r.get("customerId")) == str(top["id"]) or same_name > 1 for r in rows),
          str(rows)[:200])
    mine = [r for r in rows if str(r.get("customerId")) == str(top["id"])]
    check("snapshot owed reconciles to the cent", bool(mine) and money(mine[0].get("owed")) == money(owed[top["id"]]),
          f"{mine[0].get('owed') if mine else None} vs {owed[top['id']]}")
    deals = ask_odoo("crm.lead", "search_read", {"domain": [["partner_id", "=", top["id"]], "|", ["active", "=", True], ["active", "=", False]],
                                                 "fields": ["won_status"], "load": ""})
    for status, col in (("pending", "openDeals"), ("won", "wonDeals"), ("lost", "lostDeals")):
        want = sum(1 for x in deals if x["won_status"] == status)
        check(f"snapshot {col} = {want}", bool(mine) and int(mine[0].get(col) or 0) == want, str(mine[0].get(col) if mine else None))
    within("single-company snapshot", calls, 3)
    # Exact by default: the same name in another case, or a fragment of it, is not that company.
    if top["name"].lower() != top["name"]:
        d, rows, _ = view("OdooAccountSnapshot", {"company": top["name"].lower()})
        check("snapshot name is matched exactly (other case answers nothing)",
              not any(str(r.get("customerId")) == str(top["id"]) for r in rows), str(rows)[:150])

# THE GROUP, exact by default. The company with the most companies filed under it: the exact name
# answers that company alone, with exactly Odoo's direct subsidiaries at depth 1; a fragment does
# not answer through OdooCompanyGroup at all, and does through the explicit search.
kids = {}
for r in ask_odoo("res.partner", "search_read", {"domain": [["is_company", "=", True], ["parent_id", "!=", False]],
                                                  "fields": ["parent_id"], "load": ""}):
    kids.setdefault(r["parent_id"], set()).add(r["id"])
if not kids:
    print("  skip no company in this book has a parent company")
else:
    pid, subs = max(kids.items(), key=lambda kv: (len(kv[1]), -kv[0]))
    parent = ask_odoo("res.partner", "search_read", {"domain": [["id", "=", pid]], "fields": ["name"], "load": ""})[0]
    d, rows, calls = view("OdooCompanyGroup", {"company": parent["name"]})
    check("group answered", d.get("status") == "SUCCEEDED", str(d)[:200])
    check(f"group of '{parent['name']}' names only companies called exactly that",
          rows and all(r.get("company") == parent["name"] for r in rows), str({r.get('company') for r in rows}))
    got = {int(r["subsidiaryId"]) for r in rows if str(r.get("companyId")) == str(pid) and r.get("depth") == 1}
    check("direct subsidiaries reconcile against Odoo", got == subs, f"{sorted(got)} vs {sorted(subs)}")
    within("exact-name group, four levels down", calls, 6)
    d, rows, calls = view("OdooCompanyGroupById", {"companyId": str(pid)})
    check("group by id answers the same subsidiaries",
          {int(r["subsidiaryId"]) for r in rows if r.get("depth") == 1} == subs, str(rows)[:150])
    within("group by id", calls, 6)
    fragment = parent["name"][: max(3, len(parent["name"]) // 2)]
    if fragment != parent["name"]:
        _, rows, _ = view("OdooCompanyGroup", {"company": fragment})
        check(f"a fragment ('{fragment}') does not answer the exact view", not any(str(r.get("companyId")) == str(pid) for r in rows))
        _, rows, _ = view("OdooCompanyGroupSearch", {"nameContains": fragment.lower()})
        check(f"the explicit search finds it from '{fragment.lower()}'", any(str(r.get("companyId")) == str(pid) for r in rows))

# THE BIGGEST INVOICES: one page of the largest debts, and only the partners they name.
d, rows, calls = view("OdooOutstandingInvoices", {"limit": 10})
truth = sorted((money(r["amount_residual"]) for r in inv), reverse=True)[:10]
check("top-10 invoices reconcile against Odoo", [money(r.get("owed")) for r in rows] == truth,
      f"{[money(r.get('owed')) for r in rows]} vs {truth}")
within("top-10 outstanding invoices", calls, 2)

# THE PIPELINE OVER 60%: Odoo applies the probability filter and the order, so the top 10 is one page.
OPEN = [["active", "=", True], ["probability", "<", 100], ["partner_id", "!=", False]]
top10 = ask_odoo("crm.lead", "search_read", {"domain": OPEN + [["probability", ">=", 60]], "fields": ["expected_revenue"],
                                            "order": "expected_revenue desc, id desc", "limit": 10, "load": ""})
d, rows, calls = view("OdooOpenPipeline", {"minProbability": 60, "limit": 10})
check("open pipeline over 60% reconciles against Odoo",
      [money(r.get("expectedRevenue")) for r in rows] == [money(r["expected_revenue"]) for r in top10],
      f"{[money(r.get('expectedRevenue')) for r in rows]} vs {[money(r['expected_revenue']) for r in top10]}")
check("every row is at or over 60%", all(float(r.get("probabilityPercent") or 0) >= 60 for r in rows))
within("top-10 open deals over 60%", calls, 2)

# PIPELINE BY STAGE: every open deal, summed per stage — the figures, not just the rows.
openl = ask_odoo("crm.lead", "search_read", {"domain": OPEN, "fields": ["stage_id", "expected_revenue"]})
by_stage = {}
for r in openl:
    s = r["stage_id"][1] if r["stage_id"] else None
    n, t = by_stage.get(s, (0, 0.0)); by_stage[s] = (n + 1, t + r["expected_revenue"])
d, rows, _ = view("OdooPipelineByStage", {})
got = {}
for r in rows:
    n, t = got.get(r.get("stage"), (0, 0.0)); got[r.get("stage")] = (n + int(r.get("openDeals") or 0), t + float(r.get("expectedRevenue") or 0))
check("pipeline by stage reconciles against Odoo",
      {k: (v[0], money(v[1])) for k, v in got.items()} == {k: (v[0], money(v[1])) for k, v in by_stage.items()},
      f"{got} vs {by_stage}")

# WINS IN A WINDOW: the decided-deal door, filtered by Odoo on status and day.
won = ask_odoo("crm.lead", "search_read", {"domain": [["won_status", "=", "won"], ["partner_id", "!=", False], "|", ["active", "=", True], ["active", "=", False]],
                                           "fields": ["expected_revenue", "date_closed"], "load": ""})
days = sorted(r["date_closed"][:10] for r in won if r["date_closed"])
if not days:
    print("  skip no won deal in this book")
else:
    since = until = days[-1]
    want = sorted((money(r["expected_revenue"]) for r in won if r["date_closed"] and r["date_closed"][:10] == since), reverse=True)[:20]
    d, rows, calls = view("OdooWins", {"since": since, "until": until})
    check(f"wins on {since} reconcile against Odoo", [money(r.get("value")) for r in rows] == want,
          f"{[money(r.get('value')) for r in rows]} vs {want}")
    within(f"wins on one day", calls, 3)
    d, rows, _ = view("OdooWins", {})
    check("all-time top win reconciles", rows and money(rows[0].get("value")) == max(money(r["expected_revenue"]) for r in won),
          str(rows[:1]))

# ONE DEAL BY ID, and the vocabulary's probability is a fraction.
any_lead = ask_odoo("crm.lead", "search_read", {"domain": OPEN, "fields": ["name", "probability"], "limit": 1, "load": ""})
if any_lead:
    lid = any_lead[0]["id"]
    out = subprocess.run(["curl", "-s", "-K", auth, "-X", "POST", f"{base}/api/v1/admin/kg/execute", "-H", "Content-Type: application/json",
                          "-d", json.dumps({"cypher": f"MATCH (b:OdooBook)-[:HAS_ANY_LEAD]->(l:OdooLead) WHERE l.id = '{lid}' "
                                                      "RETURN l.name AS name, l.probability AS p, l.probabilityPercent AS pct, l.status AS status"})],
                         capture_output=True, text=True).stdout
    kg = json.loads(out, strict=False).get("rows") or []
    check(f"deal {lid} read by id", len(kg) == 1 and kg[0].get("name") == any_lead[0]["name"], str(kg)[:150])
    if kg:
        check("probability is the fraction of probabilityPercent",
              abs(float(kg[0]["p"]) * 100 - float(kg[0]["pct"])) < 1e-6 and money(kg[0]["pct"]) == money(any_lead[0]["probability"]), str(kg[0]))
        check("an open deal's status is 'open'", kg[0].get("status") == "open", str(kg[0]))
import sys
sys.exit(1 if bad else 0)
PYEOF

echo "== L3: the natural-language battery, figures not just rows =="
EXP_AMT=${TOP_OWED#*:}
# Money questions run 3x: generation is stochastic; a view-routed answer is stable, and any
# drift on any run is a failure.
for Q in "How many customers do we have" "Which customers owe us most money" "Which customers owe us most money" "Which customers owe us most money" "which is our most valuable customer"; do
  A=$(curl -s -K "$AUTHCFG" -X POST "$APPLIANCE/api/v1/admin/kg/ask" -H 'Content-Type: application/json' \
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
    # Odoo owes nothing: there is no Odoo figure to reconcile, and in a world whose invoices live in
    # a billing realm the honest answer comes from there.
    *) if [ "$TOP_OWED" = none ]; then echo "  skip NL: $Q (Odoo holds no unpaid invoices; nothing here to reconcile)"
       else check "NL: $Q (top figure)" "$EXP_AMT" "$GOT"; fi ;;
  esac
done

echo "== L5: the app's own calls =="
# An app is served at its scoped URL, /apps/<realm>/<file>; the flat /apps/<file> only redirects there.
for a in prospect.html prospect.css prospect.js; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -K "$AUTHCFG" "$APPLIANCE/apps/odoo/$a")
  check "app asset $a" "200" "$code"
done

echo "== L3b: the battery (tests/questions.yml) =="
DIR="$(dirname "$0")"
python3 - "$DIR/questions.yml" "$APPLIANCE" "$AUTHCFG" "$SEEDED" "$RECEIVABLES" <<'PYEOF' || fail=1
import json, sys, subprocess, yaml

qfile, base, auth = sys.argv[1], sys.argv[2], sys.argv[3]
have = {"seed": sys.argv[4] == "1", "receivables": sys.argv[5] == "1"}
battery = yaml.safe_load(open(qfile))
def curl(path, body):
    out = subprocess.run(["curl", "-s", "-K", auth, "-X", "POST", base + path,
                          "-H", "Content-Type: application/json", "-d", json.dumps(body)],
                         capture_output=True, text=True).stdout
    # An empty or non-JSON reply is a failed call, and is reported as one on that question rather
    # than ending the battery with a traceback.
    try:
        return json.loads(out, strict=False)
    except ValueError:
        return {"rows": [], "data": [], "error": "no JSON reply: " + out[:120]}

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
    missing = [r for r in case.get("requires", []) if not have.get(r)]
    if missing:
        print("  skip " + q + " (this book has no " + " or ".join(missing) + ")")
        continue
    a = curl("/api/v1/admin/kg/ask", {"question": q})
    rows = a.get("rows") or []
    if "matchesView" in exp:
        mv = exp["matchesView"]
        v = curl("/api/v1/views/%s/invoke" % mv["name"], {"args": mv.get("args", {})})
        vrows = v.get("data") or []
        # Same column on BOTH sides when the answer carries it (it does whenever the ask
        # routed through the view) — comparing the view's totalOwed against the answer's
        # biggest number once failed a correct answer for leading with a headcount.
        want, got = top_figure(vrows, mv.get("column")), top_figure(rows, mv.get("column"))
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

echo "== L6: Diffbot firmographics reconcile against Diffbot itself =="
# Ground truth for the enrichment layer is the enrichment SOURCE: every customer the view
# says it matched is re-asked of Diffbot Enhance directly, same key, and the headcount must
# agree exactly. Needs the deployment's DIFFBOT_TOKEN; without it this leg SKIPs loudly
# rather than passing silently — an unexercised reconciliation is not a green one.
if [ -z "$DIFFBOT_TOKEN" ]; then
  echo "  SKIP: set DIFFBOT_TOKEN to reconcile firmographics against the source"
else
  # The payload travels by ENVIRONMENT, not by pipe: `echo | python3 - <<EOF` hands the
  # heredoc to stdin as the program, so the piped JSON silently never arrives — this leg's
  # first real run (the token gates it) found it reading EOF.
  FVIEW=$(curl -s -K "$AUTHCFG" -X POST "$APPLIANCE/api/v1/views/OdooCustomerFirmographics/invoke" \
    -H 'Content-Type: application/json' -d '{"args":{}}')
  FVIEW="$FVIEW" DIFFBOT_TOKEN="$DIFFBOT_TOKEN" python3 - <<'PYEOF' || fail=1
import json, os, sys, urllib.request, urllib.parse
token = os.environ['DIFFBOT_TOKEN']
rows = json.loads(os.environ['FVIEW']).get('data') or []
# Every row is enriched by construction — the view's MATCH requires the Diffbot hop —
# so the reconciliation set is the rows that carry the join key to re-ask with.
matched = [r for r in rows if r.get('website')]
print(f"  {len(rows)} customers enriched, {len(matched)} carry the join key")
bad = 0
for r in matched:
    q = urllib.parse.urlencode({'type': 'Organization', 'url': r['website'],
                                'threshold': '0.7', 'token': token})
    with urllib.request.urlopen('https://kg.diffbot.com/kg/v3/enhance?' + q) as resp:
        data = json.load(resp)
    ents = data.get('data') or []
    truth = (ents[0].get('entity') or {}).get('nbEmployees') if ents else None
    ok = truth == r.get('headcount')
    print(("  ok   " if ok else "  FAIL ") +
          f"{r['customer']}: view headcount {r.get('headcount')} vs Diffbot {truth}")
    if not ok: bad += 1
sys.exit(1 if bad else 0)
PYEOF
fi

echo "== L7: the AI layer judges what the seed planted =="
# The judgments live in the OdooDealTriage VIEW now (classify() in-query; the lens is gone).
# A model's opinion still has no cents — labels are asserted for vocabulary and the two
# seeded chatter arcs, which were WRITTEN to be unambiguous: a judge that cannot read
# "budget approved" as positive is broken, not subtle. But the FIGURES beside the labels are
# the query's, so they now reconcile like any view's: top revenue must equal the pipeline
# view's, and a null sentiment (a deal nobody wrote on) must arrive as null, never a
# sentinel sentence in a label column.
TRIAGE=$(curl -s -K "$AUTHCFG" -X POST "$APPLIANCE/api/v1/views/OdooDealTriage/invoke" \
  -H 'Content-Type: application/json' -d '{"args":{"triage":""}}')
ATRISK=$(curl -s -K "$AUTHCFG" -X POST "$APPLIANCE/api/v1/views/OdooDealTriage/invoke" \
  -H 'Content-Type: application/json' -d '{"args":{"triage":"at_risk"}}')
PIPE=$(curl -s -K "$AUTHCFG" -X POST "$APPLIANCE/api/v1/views/OdooOpenPipeline/invoke" \
  -H 'Content-Type: application/json' -d '{"args":{}}')
TRIAGE="$TRIAGE" ATRISK="$ATRISK" PIPE="$PIPE" SEEDED="$SEEDED" python3 - <<'PYEOF' || fail=1
import json, os, sys
d = json.loads(os.environ['TRIAGE'])
bad = 0
def check(name, ok, detail=""):
    global bad
    print(("  ok   " if ok else "  FAIL ") + name + (f" ({detail})" if detail and not ok else ""))
    if not ok: bad += 1
check("view invocation succeeded", d.get("status") == "SUCCEEDED", str(d)[:150])
rows = d.get("data") or []
check("triage rows returned", len(rows) > 0)
check("triage labels stay in vocabulary",
      all(r.get("triage") in ("strategic", "standard", "at_risk") for r in rows))
check("sentiment labels stay in vocabulary (null = nobody wrote; never a sentence)",
      all(r.get("sentiment") in ("positive", "neutral", "negative", None) for r in rows))
pipe = json.loads(os.environ['PIPE']).get("data") or []
top = lambda rs, k: max((r.get(k) for r in rs if isinstance(r.get(k), (int, float))), default=None)
check("top revenue reconciles against the pipeline view",
      top(rows, "revenue") == top(pipe, "expectedRevenue"),
      f"{top(rows, 'revenue')} vs {top(pipe, 'expectedRevenue')}")
by = {r.get("deal"): r for r in rows}
# The two chatter arcs are the demo seed's; another book has neither.
if os.environ.get("SEEDED") == "1":
    atl, qf = by.get("SEED Team workflow rollout") or {}, by.get("SEED Fleet data platform") or {}
    check("seeded negative arc reads negative (Atlassian)", atl.get("sentiment") == "negative", str(atl))
    check("seeded positive arc reads positive (Qantas)", qf.get("sentiment") == "positive", str(qf))
    check("negative thread outweighs a 65% probability (at_risk)", atl.get("triage") == "at_risk", str(atl))
else:
    print("  skip the seeded chatter arcs (this book is not the demo seed)")
ar = json.loads(os.environ['ATRISK']).get("data") or []
check("the triage parameter filters (every returned row is at_risk)",
      all(r.get("triage") == "at_risk" for r in ar), str([r.get("triage") for r in ar]))
sys.exit(1 if bad else 0)
PYEOF

echo "== L8: meeting briefings (virtual cypher + synthesize) — figures reconcile beside the prose =="
# The briefing's PROSE is a model's composition and is asserted present, never parsed. The
# FIGURES travel beside it as columns and reconcile exactly against the receivables view —
# a briefing that narrates one number while its row carries another is drift, whoever wrote it.
PREP=$(curl -s -K "$AUTHCFG" -X POST "$APPLIANCE/api/v1/views/OdooMeetingBriefing/invoke" \
  -H 'Content-Type: application/json' -d '{"args":{}}')
RECV=$(curl -s -K "$AUTHCFG" -X POST "$APPLIANCE/api/v1/views/OdooReceivablesByCustomer/invoke" \
  -H 'Content-Type: application/json' -d '{"args":{"limit":100000}}')
PREP="$PREP" RECV="$RECV" SEEDED="$SEEDED" python3 - <<'PYEOF' || fail=1
import json, os, sys
d = json.loads(os.environ['PREP'])
recv = {r["customer"]: r["totalOwed"] for r in (json.loads(os.environ['RECV']).get("data") or [])}
bad = 0
def check(name, ok, detail=""):
    global bad
    print(("  ok   " if ok else "  FAIL ") + name + (f" ({detail})" if detail and not ok else ""))
    if not ok: bad += 1
check("view invocation succeeded", d.get("status") == "SUCCEEDED", str(d)[:150])
rows = d.get("data") or []
by = {r.get("meeting"): r for r in rows}
# The two meetings are the demo seed's; on another book the figures beside every briefing still
# reconcile against the receivables view.
seeded = [("Qantas quarterly review", "Qantas"), ("Atlassian rollout check-in", "Atlassian")]
if os.environ.get("SEEDED") != "1":
    print("  skip the seeded meetings (this book is not the demo seed)")
    seeded = []
mismatched = [r.get("meeting") for r in rows
              if round(float(r.get("owed") or 0), 2) != round(float(recv.get(r.get("customer")) or 0), 2)]
check(f"every briefing's owed figure matches the receivables view ({len(rows)} briefings)", not mismatched, str(mismatched[:5]))
for meeting, customer in seeded:
    r = by.get(meeting) or {}
    check(f"'{meeting}' is prepared", bool(r))
    if not r: continue
    check(f"  {customer} owed figure matches the receivables view",
          r.get("owed") == recv.get(customer), f"{r.get('owed')} vs {recv.get(customer)}")
    check(f"  {customer} briefing is substantive prose", len(str(r.get("briefing") or "")) > 200)
sys.exit(1 if bad else 0)
PYEOF

echo "== L8: the write verbs, written and undone =="
# Opt-in: this leg writes to the Odoo it is pointed at, and someone may point this script at a
# customer's install. It undoes everything it writes, but writing at all should be a decision.
if [ "$VERIFY_WRITES" = 1 ]; then
  ODOO="$ODOO" ODOO_KEY="$ODOO_KEY" APPLIANCE="$APPLIANCE" AUTH="$AUTH" sh "$(dirname "$0")/verify-writes.sh" || fail=1
else
  echo "  SKIP: set VERIFY_WRITES=1 to exercise the write verbs (each is undone afterwards)"
fi

[ "$fail" = 0 ] && echo "ALL CHECKS PASS" || { echo "DRIFT DETECTED"; exit 1; }
