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
# Whether an answer is the whole truth is the ENGINE's to say, and it says it beside the rows: a
# query's `error`, `reason` and `warnings` (each opening with its code), a view's `status`,
# `outcome` and `warnings`. A figure read past them reports a source that failed under load, or a
# page it capped, as drift in the realm. So every figure goes through short(): a refusal reads
# REFUSED and a short answer PARTIAL <figure>: <the engine's reason>, which no check expects.
# Exported, so each Python leg below runs the same definition (`exec(os.environ["SHORT_PY"])`).
SHORT_PY=$(cat <<'PY'
import json, sys
# Raw warning codes that mean rows or values may be missing (the engine's incompleteness kinds).
# Cost notes (FILTERED_IN_GRAPH, AGGREGATE_NOT_PUSHED, EMPTY_NOT_KEPT, PUSHDOWN_VALUE_UNMATCHED),
# FILTER_STARVED (an honest empty), STALE_COPY, FIELDS_WITHHELD and UNKNOWN_VIA leave every row in place.
SHORT_CODES = (
    "PARTIAL_RESULT", "PRODUCER_ERROR", "NEEDS_FILTER", "NEEDS_PRODUCER", "FILTER_REJECTED",
    "UNPUSHED_FILTER", "AMBIGUOUS_LABEL", "INCOMPLETE_TRAVERSAL", "INCOMPLETE_RANKING",
    "INCOMPLETE_AGGREGATE", "INCOMPLETE_INPUT", "MATERIALIZATION_FAILED", "REDUCTION_FAILED",
    "UNPARSEABLE_ANSWER", "TERMS_UNAVAILABLE", "COMPUTE_FAILED", "PROPERTY_NOT_STORED",
    "FOLLOW_CAPPED", "UNLINKED_CHILDREN", "RESOLUTION_DROPPED", "AGENTIC_DEGRADED",
    "SOURCE_UNANSWERED",
)
# The typed `reason` a query result carries when it is not a clean answer and not an honest empty.
SHORT_REASONS = ("UNBOUNDED", "PARTIAL_NOT_MATCHED", "UNPUSHED_FILTER", "DISCONNECTED",
                 "INTERNAL_ERROR", "WRITE_IN_PROGRESS", "KILLED", "TOO_EXPENSIVE")
# Public warning codes on a view envelope that mean the same.
SHORT_PUBLIC = ("PARTIAL", "REDUCTION_FAILED", "COMPUTE_FAILED", "PROPERTY_NOT_STORED",
                "AGENTIC_DEGRADED", "RATE_LIMITED", "SOURCE_UNAVAILABLE", "SOURCE_REJECTED",
                "INVALID_FILTER", "UNPUSHED_FILTER", "TOO_BROAD", "FETCH_CAPPED",
                "INDEX_UNAVAILABLE", "ARGUMENT_REFUSED")


def short(d, figure=None):
    tag = "PARTIAL" if figure is None else "PARTIAL %s" % (figure,)
    if not isinstance(d, dict):
        return "REFUSED: not an engine answer: " + str(d)[:160]
    if "outcome" in d or "status" in d:  # a view envelope
        err = d.get("error") or {}
        if d.get("status") != "SUCCEEDED":
            return "REFUSED: %s %s" % (d.get("status"), (err.get("code", "") + " " + err.get("message", "")).strip()[:160] if isinstance(err, dict) else str(err)[:160])
        ws = [w for w in d.get("warnings") or [] if isinstance(w, dict) and w.get("code") in SHORT_PUBLIC]
        if d.get("outcome") not in ("OK", "EMPTY") or ws:
            why = ws[0]["code"] + ": " + ws[0].get("message", "") if ws else "outcome " + str(d.get("outcome"))
            return "%s: %s" % (tag, why[:200])
        return None
    if d.get("error"):
        return "REFUSED: " + str(d["error"])[:160]
    if d.get("run"):
        return "%s: the run had not finished (%s)" % (tag, d["run"])
    ws = [w for w in d.get("warnings") or [] if isinstance(w, str) and w.split(":", 1)[0].strip() in SHORT_CODES]
    if ws:
        return "%s: %s" % (tag, ws[0][:200])
    if d.get("reason") in SHORT_REASONS:
        return "%s: reason %s" % (tag, d["reason"])
    return None
PY
)
export SHORT_PY
# The figure in column n of a query answer.
n() { printf '%s' "$1" | python3 -c "$SHORT_PY
d = json.loads(sys.stdin.read(), strict=False); r = d.get('rows') or []
v = r[0].get('n') if r else 0
print(short(d, v) or v)"; }
# whole ANSWER SNIPPET: run SNIPPET over the parsed answer, as `d`, only when the engine says it is
# whole; otherwise print why it is not, in place of the figure.
whole() { printf '%s' "$1" | python3 -c "$SHORT_PY
d = json.loads(sys.stdin.read(), strict=False); s = short(d)
if s: print(s); sys.exit(0)
$2"; }

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
check "kg customer count" "$CUSTOMERS" "$(n "$KG")"

echo "== L1a: the people at every company, more companies than one batched fetch may ask for =="
# Every company in the book is more companies (6,855 on the demo book) than HAS_ACCOUNT_CONTACT may
# ask Odoo for at once, so this is answered from the contacts book matched on parent_id — and it
# must be the people Odoo files under a company, exactly, by Odoo's own search_count.
PEOPLE=$(curl -s -X POST "$ODOO/json/2/res.partner/search_count" -H "Authorization: Bearer $ODOO_KEY" \
  -H 'Content-Type: application/json' -d '{"domain":[["is_company","=",false],["parent_id.is_company","=",true]]}')
KG=$(curl -s -K "$AUTHCFG" -X POST "$APPLIANCE/api/v1/admin/kg/execute" -H 'Content-Type: application/json' \
  -d '{"cypher":"MATCH (b:OdooBook)-[:HAS_COMPANY]->(k:OdooCustomer)-[:HAS_ACCOUNT_CONTACT]->(ct:OdooContact) RETURN count(DISTINCT ct) AS n"}')
check "people at every company (vs search_count)" "$PEOPLE" "$(n "$KG")"
# The company with the most people, and how many, from Odoo's records: the sweep must put each person
# under their own company, not only count them.
BUSIEST=$(curl -s -X POST "$ODOO/json/2/res.partner/search_read" -H "Authorization: Bearer $ODOO_KEY" \
  -H 'Content-Type: application/json' -d '{"domain":[["is_company","=",false],["parent_id.is_company","=",true]],"fields":["parent_id"],"load":""}' | py "
import json,sys,collections
n=collections.Counter(r['parent_id'] for r in json.load(sys.stdin))
pid,c=sorted(n.items(), key=lambda kv: (-kv[1], kv[0]))[0]; print(f'{pid}:{c}')")
KG=$(curl -s -K "$AUTHCFG" -X POST "$APPLIANCE/api/v1/admin/kg/execute" -H 'Content-Type: application/json' \
  -d '{"cypher":"MATCH (b:OdooBook)-[:HAS_COMPANY]->(k:OdooCustomer)-[:HAS_ACCOUNT_CONTACT]->(ct:OdooContact) RETURN toInteger(k.id) AS company, count(ct) AS people ORDER BY people DESC, company LIMIT 1"}')
check "the company with the most people" "$BUSIEST" "$(whole "$KG" 'r=(d.get("rows") or [{}])[0]; print("%s:%s" % (r.get("company"), r.get("people")))')"

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
  check "subsidiaries of $PARENT (vs L0)" "$GROUP" "$PARENT:$(whole "$DOWN" 'print(",".join(sorted({str(r["id"]) for r in d["rows"]}, key=int)))')"
  check "each leads back up to $PARENT" "$PARENT" "$(whole "$DOWN" 'print(",".join(sorted({str(r["up"]) for r in d["rows"]})) or "none")')"
fi

echo "== L2: the view, id-deduped, reconciles to the cent =="
VIEW=$(curl -s -K "$AUTHCFG" -X POST "$APPLIANCE/api/v1/views/OdooPipelineReceivables/invoke" \
  -H 'Content-Type: application/json' -d '{"args":{"stage":"Proposition"}}')
VIEW_TOP=$(whole "$VIEW" "
rows=d.get('data') or []
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
exec(os.environ["SHORT_PY"])
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
    # A short or refused answer fails here, with the engine's reason, whatever the checks made
    # from its rows go on to say: a negative check passes on rows that are not all there.
    s = short(d, len(d.get("data") or []))
    if s: check(f"view {name} {json.dumps(args)} answered whole", False, s)
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
    kd = json.loads(out, strict=False)
    s = short(kd, len(kd.get("rows") or []))
    if s: check(f"deal {lid} answered whole", False, s)
    kg = kd.get("rows") or []
    check(f"deal {lid} read by id", len(kg) == 1 and kg[0].get("name") == any_lead[0]["name"], str(kg)[:150])
    if kg:
        check("probability is the fraction of probabilityPercent",
              abs(float(kg[0]["p"]) * 100 - float(kg[0]["pct"])) < 1e-6 and money(kg[0]["pct"]) == money(any_lead[0]["probability"]), str(kg[0]))
        check("an open deal's status is 'open'", kg[0].get("status") == "open", str(kg[0]))
import sys
sys.exit(1 if bad else 0)
PYEOF

echo "== L2c: numbers Odoo answers itself — search_count and read_group =="
# A count or total over a door that declares `aggregates:` is one source call per measure, made
# with the aggregate's own arguments. Each figure is checked three ways: against Odoo asked
# directly, against the same figure folded from the records (a measure no door declares, `min` of
# the name, makes the engine read them), and by the calls it cost — which are printed, so the
# difference between the two reads is on the record.
ODOO="$ODOO" ODOO_KEY="$ODOO_KEY" APPLIANCE="$APPLIANCE" AUTHCFG="$AUTHCFG" python3 - <<'PYEOF' || fail=1
import json, os, subprocess, urllib.request
odoo, key = os.environ['ODOO'], os.environ['ODOO_KEY']
exec(os.environ["SHORT_PY"])
base, auth = os.environ['APPLIANCE'], os.environ['AUTHCFG']

def ask_odoo(model, method, body):
    req = urllib.request.Request(f"{odoo}/json/2/{model}/{method}", data=json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req) as resp:
        return json.load(resp)

def kg(cypher):
    out = subprocess.run(["curl", "-s", "-K", auth, "-X", "POST", f"{base}/api/v1/admin/kg/execute",
                          "-H", "Content-Type: application/json", "-d", json.dumps({"cypher": cypher})],
                         capture_output=True, text=True).stdout
    d = json.loads(out, strict=False)
    s = short(d, (d.get("rows") or [{}])[0].get("n") if d.get("rows") else 0)
    if s: check(f"answered whole: {cypher[:120]}", False, s)
    return d

bad = 0
def check(name, ok, detail=""):
    global bad
    print(("  ok   " if ok else "  FAIL ") + name + (f" ({detail})" if detail and not ok else ""))
    if not ok: bad += 1
def calls(label, d):
    print(f"    {label}: {d.get('apiCalls')} call(s)")
    for c in d.get("apiCallLog") or []: print(f"      {c[:240]}")

money = lambda x: round(float(x or 0), 2)
UNPAID = [["move_type", "=", "out_invoice"], ["state", "=", "posted"], ["payment_state", "in", ["not_paid", "partial"]]]
inv = ask_odoo("account.move", "search_read", {"domain": UNPAID, "fields": ["partner_id", "amount_residual"], "load": ""})

# THE BOOK. How many unpaid invoices, and how much is owed on them.
book = "MATCH (b:OdooBook {scope: 'all'})-[:HAS_UNPAID_INVOICE]->(i:OdooInvoice)"
pushed = kg(f"{book} RETURN count(i) AS n, sum(i.amount_residual) AS owed")
folded = kg(f"{book} RETURN count(i) AS n, sum(i.amount_residual) AS owed, min(i.name) AS first")
p, f = (pushed.get("rows") or [{}])[0], (folded.get("rows") or [{}])[0]
check(f"book unpaid count = Odoo's {len(inv)}", p.get("n") == len(inv), str(p))
check(f"book owed = Odoo's {money(sum(r['amount_residual'] for r in inv))}",
      money(p.get("owed")) == money(sum(r["amount_residual"] for r in inv)), str(p))
check("book count and owed = the same folded from the records",
      (p.get("n"), money(p.get("owed"))) == (f.get("n"), money(f.get("owed"))), f"{p} vs {f}")
check("book count is one search_count and one read_group",
      sorted(c.split(" ")[0] for c in pushed.get("apiCallLog") or []) == sorted(["invoicesSearchCount", "invoicesReadGroup"])
      or pushed.get("apiCalls") == 2, str(pushed.get("apiCallLog")))
calls("pushed", pushed); calls("from records", folded)

# PER CUSTOMER. The five customers owing most, counted and totalled by read_group in one call each.
owed = {}
for r in inv: owed.setdefault(r["partner_id"], []).append(r["amount_residual"])
top = sorted(owed, key=lambda k: -sum(owed[k]))[:5]
if not top:
    print("  skip per-customer: Odoo holds no unpaid invoices")
else:
    ids = ", ".join(f"'{i}'" for i in top)
    q = f"MATCH (b:OdooBook {{scope: 'all'}})-[:HAS_CUSTOMER]->(c:OdooCustomer) WHERE c.id IN [{ids}] MATCH (c)-[:HAS_UNPAID_INVOICE]->(i:OdooInvoice)"
    pushed = kg(f"{q} RETURN c.id AS id, count(i) AS n, sum(i.amount_residual) AS owed ORDER BY id")
    folded = kg(f"{q} RETURN c.id AS id, count(i) AS n, sum(i.amount_residual) AS owed, min(i.name) AS first ORDER BY id")
    got = {str(r["id"]): (r["n"], money(r["owed"])) for r in pushed.get("rows") or []}
    want = {str(k): (len(owed[k]), money(sum(owed[k]))) for k in top}
    check("per-customer count and owed = Odoo's", got == want, f"{got} vs {want}")
    check("per-customer = the same folded from the records",
          got == {str(r["id"]): (r["n"], money(r["owed"])) for r in folded.get("rows") or []}, str(folded.get("rows")))
    calls("pushed", pushed); calls("from records", folded)

# THE DEALS. Every deal on the book, open, won or lost: how many, and their expected revenue.
LEADS = ["|", ["active", "=", True], ["active", "=", False]]
leads = ask_odoo("crm.lead", "search_read", {"domain": LEADS + [["partner_id", "!=", False]],
                                             "fields": ["partner_id", "expected_revenue"], "load": ""})
book = "MATCH (b:OdooBook {scope: 'all'})-[:HAS_ANY_LEAD]->(l:OdooLead)"
pushed = kg(f"{book} RETURN count(l) AS n, sum(l.expected_revenue) AS revenue")
folded = kg(f"{book} RETURN count(l) AS n, sum(l.expected_revenue) AS revenue, min(l.name) AS first")
p, f = (pushed.get("rows") or [{}])[0], (folded.get("rows") or [{}])[0]
check(f"deal count = Odoo's {len(leads)}", p.get("n") == len(leads), str(p))
check(f"deal revenue = Odoo's {money(sum(r['expected_revenue'] for r in leads))}",
      money(p.get("revenue")) == money(sum(r["expected_revenue"] for r in leads)), str(p))
check("deal count and revenue = the same folded from the records",
      (p.get("n"), money(p.get("revenue"))) == (f.get("n"), money(f.get("revenue"))), f"{p} vs {f}")
check("deal count is one call per measure", pushed.get("apiCalls") == 2, str(pushed.get("apiCallLog")))
calls("pushed", pushed); calls("from records", folded)

# A CASE-SENSITIVE CONTAINS is widened by ilike, so its count must come from the records.
word = next((w for r in ask_odoo("crm.lead", "search_read", {"domain": LEADS, "fields": ["name"], "limit": 1})
             for w in r["name"].split() if len(w) > 3 and w.isalpha()), None)
if word:
    q = f"{book} WHERE l.name CONTAINS '{word}' RETURN count(l) AS n"
    want = sum(1 for r in ask_odoo("crm.lead", "search_read", {"domain": LEADS + [["partner_id", "!=", False], ["name", "ilike", word]],
                                                               "fields": ["name"], "load": ""}) if word in r["name"])
    got = kg(q)
    check(f"count of deals named with '{word}' (case as written) = {want}", (got.get("rows") or [{}])[0].get("n") == want, str(got.get("rows")))

# PER CUSTOMER. The five customers with most deals: count and revenue by read_group, one call each.
per = {}
for r in leads: per.setdefault(r["partner_id"], []).append(r["expected_revenue"])
# A deal's partner need not be a customer (customer_rank > 0), and HAS_CUSTOMER reaches only those.
customers = {r["id"] for r in ask_odoo("res.partner", "search_read", {"domain": [["customer_rank", ">", 0], ["id", "in", list(per)]], "fields": ["id"]})}
top = sorted((k for k in per if k in customers), key=lambda k: (-len(per[k]), k))[:5]
ids = ", ".join(f"'{i}'" for i in top)
q = f"MATCH (b:OdooBook {{scope: 'all'}})-[:HAS_CUSTOMER]->(c:OdooCustomer) WHERE c.id IN [{ids}] MATCH (c)-[:HAS_OPPORTUNITY]->(l:OdooLead)"
pushed = kg(f"{q} RETURN c.id AS id, count(l) AS n, sum(l.expected_revenue) AS revenue ORDER BY id")
folded = kg(f"{q} RETURN c.id AS id, count(l) AS n, sum(l.expected_revenue) AS revenue, min(l.name) AS first ORDER BY id")
got = {str(r["id"]): (r["n"], money(r["revenue"])) for r in pushed.get("rows") or []}
want = {str(k): (len(per[k]), money(sum(per[k]))) for k in top}
check("per-customer deal count and revenue = Odoo's", got == want, f"{got} vs {want}")
check("per-customer = the same folded from the records",
      got == {str(r["id"]): (r["n"], money(r["revenue"])) for r in folded.get("rows") or []}, str(folded.get("rows")))
calls("pushed", pushed); calls("from records", folded)

# HOW MANY CUSTOMERS, COMPANIES, PARTNERS. Each partner door declares a search_count over its own
# domain, so a count is one call — or none, when an earlier check in this run left the answer in
# the cache — where it used to read every record. Each is checked against Odoo asked directly and
# against the same count folded from the records, and a filter Odoo applies exactly rides along.
def one_count(d):
    log = d.get("apiCallLog") or []
    return d.get("apiCalls") == 0 or (d.get("apiCalls") == 1 and log and log[0].split(" ")[0] == "partnersSearchCount")
def partner_count(label, door, domain, where=""):
    want = ask_odoo("res.partner", "search_count", {"domain": domain})
    q = f"MATCH (b:OdooBook {{scope: 'all'}})-[:{door}]->(c:OdooCustomer){where}"
    pushed = kg(f"{q} RETURN count(c) AS n")
    folded = kg(f"{q} RETURN count(c) AS n, min(c.name) AS first")
    p, f = (pushed.get("rows") or [{}])[0].get("n"), (folded.get("rows") or [{}])[0].get("n")
    check(f"{label} = Odoo's {want}", p == want, f"got {p}")
    check(f"{label} = the same folded from the records", p == f, f"{p} vs {f}")
    check(f"{label} is one search_count", one_count(pushed), str(pushed.get("apiCallLog")))
    calls("pushed", pushed); calls("from records", folded)
    return pushed

CUST = [["customer_rank", ">", 0]]
partner_count("how many customers", "HAS_CUSTOMER", CUST)
partner_count("how many companies", "HAS_COMPANY", [["is_company", "=", True]])
partner_count("how many partners", "HAS_PARTNER", [])
partner_count("how many partners are companies", "HAS_PARTNER", [["is_company", "=", True]], " WHERE c.is_company = 'true'")
top = ask_odoo("res.partner", "read_group", {"domain": CUST + [["country_id", "!=", False]], "fields": ["country_id"],
                                             "groupby": ["country_id"], "orderby": "country_id_count desc", "limit": 1})
if top:
    country = top[0]["country_id"][1].replace("'", "\\'")
    partner_count(f"how many customers in {country}", "HAS_CUSTOMER", CUST + [["country_id.name", "=", top[0]["country_id"][1]]],
                  f" WHERE c.country = '{country}'")

# A CONTAINS the query case-folds is exact under ilike and is still one search_count; one written
# case-sensitively is widened by ilike, and a fragment holding % or _ is a wildcard to ilike, so
# both of those are counted from the records — and must still be right.
name = next((r["name"] for r in ask_odoo("res.partner", "search_read", {"domain": CUST, "fields": ["name"], "limit": 1, "order": "id"})), "")
word = next((w for w in name.split() if len(w) > 3 and w.isalpha()), None)
if word:
    names = [r["name"] for r in ask_odoo("res.partner", "search_read", {"domain": CUST + [["name", "ilike", word]], "fields": ["name"]})]
    q = "MATCH (b:OdooBook {scope: 'all'})-[:HAS_CUSTOMER]->(c:OdooCustomer)"
    folded_ci = kg(f"{q} WHERE toLower(c.name) CONTAINS '{word.lower()}' RETURN count(c) AS n")
    want = sum(1 for n in names if word.lower() in n.lower())
    check(f"customers named with '{word.lower()}' (any case) = {want}", (folded_ci.get("rows") or [{}])[0].get("n") == want, str(folded_ci.get("rows")))
    check(f"customers named with '{word.lower()}' (any case) is one search_count", one_count(folded_ci), str(folded_ci.get("apiCallLog")))
    calls("case-folded CONTAINS", folded_ci)
    cs = kg(f"{q} WHERE c.name CONTAINS '{word.upper()}' RETURN count(c) AS n")
    want = sum(1 for n in names if word.upper() in n)
    check(f"customers named with '{word.upper()}' (case as written) = {want}", (cs.get("rows") or [{}])[0].get("n") == want, str(cs.get("rows")))
wild = kg("MATCH (b:OdooBook {scope: 'all'})-[:HAS_CUSTOMER]->(c:OdooCustomer) WHERE toLower(c.name) CONTAINS '%' RETURN count(c) AS n")
want = ask_odoo("res.partner", "search_count", {"domain": CUST + [["name", "like", "\\%"]]})
check(f"customers named with a literal '%' = {want}, not every customer", (wild.get("rows") or [{}])[0].get("n") == want, str(wild.get("rows")))

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
  GOT=$(whole "$A" "
rows=d.get('rows') or []
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
import json, os, sys, subprocess, yaml
exec(os.environ["SHORT_PY"])

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
    # An answer the engine marks short is not the ask's figure, however it compares.
    s = short(a, len(rows))
    if s:
        print("  FAIL " + q + " -> " + s); bad += 1
        continue
    if "matchesView" in exp:
        mv = exp["matchesView"]
        v = curl("/api/v1/views/%s/invoke" % mv["name"], {"args": mv.get("args", {})})
        vrows = v.get("data") or []
        # Same column on BOTH sides when the answer carries it (it does whenever the ask
        # routed through the view) — comparing the view's totalOwed against the answer's
        # biggest number once failed a correct answer for leading with a headcount.
        want, got = top_figure(vrows, mv.get("column")), top_figure(rows, mv.get("column"))
        if short(v):
            ok, note = False, " (view: %s)" % short(v, len(vrows))
        elif not vrows:
            # The view ran and found nothing — no win this quarter yet, a book that owes nothing. Its
            # figure is "none", and the ask matches it by stating no figure: demanding a number here
            # failed every honest answer, and passed only an ask that invented one.
            ok, note = got is None, " (view: no rows, so the ask must state no figure)"
        else:
            ok, note = got == want, " (view: %s)" % want
        print(("  ok   " if ok else "  FAIL ") + q + " -> " + str(got) + note)
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
exec(os.environ["SHORT_PY"])
token = os.environ['DIFFBOT_TOKEN']
fview = json.loads(os.environ['FVIEW'])
rows = fview.get('data') or []
if short(fview, len(rows)):
    print("  FAIL OdooCustomerFirmographics: " + short(fview, len(rows))); sys.exit(1)
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
exec(os.environ["SHORT_PY"])
d = json.loads(os.environ['TRIAGE'])
bad = 0
def check(name, ok, detail=""):
    global bad
    print(("  ok   " if ok else "  FAIL ") + name + (f" ({detail})" if detail and not ok else ""))
    if not ok: bad += 1
check("view invocation succeeded", d.get("status") == "SUCCEEDED", str(d)[:150])
for label, env in (("OdooDealTriage", "TRIAGE"), ("OdooDealTriage at_risk", "ATRISK"), ("OdooOpenPipeline", "PIPE")):
    v = json.loads(os.environ[env])
    check(f"{label} answered whole", not short(v), short(v, len(v.get("data") or [])))
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
exec(os.environ["SHORT_PY"])
d = json.loads(os.environ['PREP'])
rv = json.loads(os.environ['RECV'])
recv = {r["customer"]: r["totalOwed"] for r in (rv.get("data") or [])}
bad = 0
def check(name, ok, detail=""):
    global bad
    print(("  ok   " if ok else "  FAIL ") + name + (f" ({detail})" if detail and not ok else ""))
    if not ok: bad += 1
check("view invocation succeeded", d.get("status") == "SUCCEEDED", str(d)[:150])
for label, v in (("OdooMeetingBriefing", d), ("OdooReceivablesByCustomer", rv)):
    check(f"{label} answered whole", not short(v), short(v, len(v.get("data") or [])))
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
