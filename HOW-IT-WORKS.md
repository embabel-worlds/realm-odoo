# How realm-odoo works

This realm turns an Odoo instance into part of an Embabel world: its CRM, invoices, calendar
and chatter become graph traversals, joinable with everything else the world knows — company
firmographics, live news, model judgment — through one query surface. This document explains
the mechanism layer by layer, with the actual queries.

The one rule everything else follows: **the API is the only door.** Every record arrives
through Odoo's JSON-2 endpoints (`POST /json/2/<model>/<method>`), authenticated as a normal
user, subject to every access rule Odoo enforces. Nothing reads the database. The same rule
holds on the way back in: the seed script creates demo records through `create` and
`message_post`, never SQL.

## Layer 1 — the vendored API surface (`apis/`)

`apis/apis.yml` names the API, its auth (`bearer`, key from the `ODOO_API_KEY` environment
variable) and points at `odoo-json2.json`: a small, hand-vendored OpenAPI spec describing the
handful of `search_read` operations the realm actually uses (leads, partners, invoices,
orders, messages, calendar, activities). Vendoring is deliberate — the spec is the contract,
pinned in the repo, not discovered at runtime from a moving server.

## Layer 2 — producers (`producers/odoo.yml`)

A producer is one parameterized fetch: an operation, a domain, a field list, and a slot where
the engine injects join keys. Two shapes recur:

**Keyed doors** fetch records *for* particular anchors. The engine batches the anchor keys
into the domain's `IN` list:

```yaml
- name: unpaidInvoicesByPartner
  operation: invoicesSearchRead
  keyType: int                 # Odoo domains are TYPED: partner_id in ["9"] matches NOTHING, silently
  keyArg: "domain.0.2"         # keys land in the IN list of the first domain clause
  echoKeyAs: partnerKey        # each record is stamped with the key that fetched it
  args:
    domain:
      - ["partner_id", "in", []]
      - ["move_type", "=", "out_invoice"]
      - ["state", "=", "posted"]
      - ["payment_state", "in", ["not_paid", "partial"]]
    load: ""                   # many2one fields come back as BARE IDS — what joins key on
```

Three details carry most of the correctness weight, each learned from a live failure:
`keyType: int` (string keys silently match nothing in a typed domain), `echoKeyAs` (records
attribute back to the anchor that asked by the *echoed* key, never by guessing), and
`load: ""` (without it `partner_id` arrives as an `[id, name]` pair and every traversal
matches nothing).

**Book doors** fetch whole sets — all customers, all open leads, all meetings — behind a
single default anchor, so questions about the collection need no literal nobody could know.

## Layer 3 — types and virtual joins (`types/`)

Types declare what the records *are* and how they are reached. A join is declared on the
**target** type and names the anchor it hangs off:

```yaml
- name: OdooBook            # the default-seeded root: `scope` has identity + default "all"
- name: OdooCustomer
  virtualJoins:
    - { anchorLabel: OdooBook,    relationship: HAS_CUSTOMER,  producer: customersAll, ... }
    - { anchorLabel: OdooLead,    relationship: LEAD_OF,       producer: customersById, ... }
    - { anchorLabel: OdooMeeting, relationship: MEETING_WITH,  keyField: partner_ids, ... }
```

`MEETING_WITH` is a per-element join over a *list* key: a meeting's attendee ids fan out to
one fetch per attendee, so "who am I meeting and what do they owe us" is a single traversal.

`OdooBook` is the trick that makes bare questions work. Its `scope` property carries
`identity: "true", default: "all"`, so a query that writes `MATCH (b:OdooBook)` with no pin
self-seeds — "how many customers do we have" needs no magic literal.

Nothing is copied anywhere. When a query touches these labels, the engine probes which
anchors are bound, calls the producers for exactly those keys, materializes the records into
the graph *transiently for that one transaction*, runs the Cypher, and rolls the records
back. Odoo stays the system of record; the graph is a query-time projection of it.

## Layer 4 — the bridges (`types/diffbot.yml`, `types/news.yml`)

Joins accumulate across realms by design: this realm contributes edges *into* types other
realms own.

```yaml
- name: DiffbotOrganization      # realm-diffbot owns this type; we only add a door into it
  virtualJoins:
    - anchorLabel: OdooCustomer
      relationship: HAS_DIFFBOT_ORG
      keyField: website          # a DOMAIN identifies a company; a name does not
      producer: orgEnhanceByDomain
```

The key choice is the honesty choice. Domains are strong evidence — `bunnings.com.au`
resolves to exactly one company, whose record says its ultimate parent is Wesfarmers. Names
are weak evidence, so the name-based fallback join must be pinned explicitly (`{via:'name'}`)
and the news join (`HAS_NEWS`, keyed on customer name against Brave news) is only ever
*attributed* through the Diffbot hop in curated views: a fictional demo customer's name must
never attract a real company's headlines. A customer whose website is a placeholder resolves
to nothing, and the views present that absence as the honest answer.

## Layer 5 — views (`views/`)

Views are the deterministic answer surface: named, parameterized queries whose joins, dedupe
and aggregation are written once, tested to the cent, and *selected* by the natural-language
ask rather than regenerated per question. Every view returns ids beside display columns
(`customerId`, `leadId`, `invoiceId`) — dedupe and record-linking both key on ids, never on
names, because names duplicate and figures merged by name once inflated a demo total.

The signature cross-system query, verbatim from `OdooDebtorOwnership`:

```cypher
MATCH (b:OdooBook)-[:HAS_CUSTOMER]->(c:OdooCustomer)-[:HAS_UNPAID_INVOICE]->(i:OdooInvoice)
WITH c, sum(i.amount_residual) AS totalOwed
MATCH (c)-[:HAS_DIFFBOT_ORG]->(d:DiffbotOrganization)
WHERE d.ultimateParentName IS NOT NULL AND d.ultimateParentName <> d.name
RETURN c.id AS customerId, c.name AS debtor, totalOwed,
       d.ultimateParentName AS ultimateOwner, toInteger(d.nbEmployees) AS employees
ORDER BY totalOwed DESC
```

One query, two systems: the receivables aggregation runs over Odoo's invoices, the ownership
hop over Diffbot's knowledge graph. Odoo alone cannot answer "which of our debtors belong to
a larger corporate group"; neither can Diffbot. The join can, with the arithmetic done once,
in a view the battery reconciles.

A view's `description` is load-bearing: it is the vocabulary the ask surface's selector
matches questions against. Every phrasing that ever failed to route gets added to the
description of the view that should have answered it — that is the upgrade path for the
natural-language surface, and it lives in this repo, not in a prompt.

## Layer 6 — the AI layer

Judgment lives in two places, chosen by a simple rule: **a view must stay deterministic in
its figures; prose and labels may be model-made, but always beside exact columns, never
instead of them.**

**In-query AI** — the engine exposes LLM reductions as Cypher aggregation functions
(`synthesize`, `summarize`, `classify`, `argmax`, …). `OdooMeetingBriefing` is the show
piece: one Virtual Cypher query walks meeting → attendees → debt → open deals → chatter →
firmographics → news, assembles a per-meeting fact text, and reduces it:

```cypher
MATCH (b:OdooBook)-[:HAS_MEETING]->(m:OdooMeeting)-[:MEETING_WITH]->(c:OdooCustomer)
WHERE m.start >= toString(date()) AND toLower(c.name) CONTAINS toLower($customer)
OPTIONAL MATCH (c)-[:HAS_UNPAID_INVOICE]->(i:OdooInvoice)
WITH b, m, c, count(DISTINCT i) AS unpaid, coalesce(sum(i.amount_residual),0) AS owed
OPTIONAL MATCH (b)-[:HAS_OPEN_LEAD]->(l:OdooLead)-[:LEAD_OF]->(c)
OPTIONAL MATCH (l)-[:HAS_MESSAGE]->(msg:OdooMessage)
-- ... two more stages assemble deal facts, thread text, firmographics, gated news ...
RETURN m.id AS meetingId, m.name AS meeting, m.start AS starts,
       c.id AS customerId, c.name AS customer, owed, unpaid AS unpaidInvoices,
       synthesize(factText, 'a meeting briefing for the salesperson attending: ...') AS briefing
ORDER BY starts
```

The figures (`owed`, `unpaidInvoices`) are computed by the query and travel beside the
prose; the harness reconciles them against the receivables view exactly. The model narrates
only the facts the query handed it, and is instructed to state absences rather than invent.

**Classification in-query** — `OdooDealTriage` classifies every open opportunity
(strategic / standard / at_risk) and reads sentiment from each deal's chatter thread, both
via the `classify()` aggregation — the label set as its second argument, the rubric defining
what each label means as its third. It began life as a lens composing three queries in
script; the engine's classify() made the composition one query, so the judgments moved into
a view and its figures joined the reconciled surface. Triage is judged in a `WITH` so the
query can filter on it — the filterable-aggregation lane stamps the label before the query
runs — which is what lets the selector bind "which deals are at risk" as `triage='at_risk'`
instead of declining for an inexpressible constraint. Sentiment stays null for a deal
nobody has written on: silence is not neutral, it is unknown.

## Layer 7 — how a question becomes an answer

1. **Selection first.** The ask surface reads the catalog — every view and lens with its
   description and parameters — and routes the question to one when it fits *every*
   constraint, binding parameters (including computed date windows) from the question.
2. **Generation as fallback.** Only when nothing fits does a model write Cypher, under the
   authoring rules (stay in the realm's types, aggregate with DISTINCT across fan-outs,
   reach labels through their declared doors).
3. **The battery guards all of it.** `tests/questions.yml` holds the questions users
   actually type; money and count questions assert `matchesView` — the natural-language
   answer's figure must equal the curated view's, to the cent.

## Layer 8 — seed and tests

`seed/` creates the demo book through Odoo's own API: real companies (Atlassian, Canva,
Qantas, Bunnings) with fictional debts, deals, chatter arcs and meetings — fictional
relationship, real entity, so every enrichment join resolves while the stock fictional
customers remain as the honest contrast. Gated (`--yes`), idempotent, removable
(`--remove`).

`tests/verify.sh` is the reconciliation ladder — L0 asks Odoo directly and every layer above
must agree exactly: traversals (L1), views to the cent (L2), the natural-language battery
with money asked three times (L3/L3b), app assets (L5), firmographics re-asked of Diffbot
itself (L6), the AI judgments against the seeded, deliberately unambiguous chatter arcs
(L7), and meeting briefings' figures against the receivables view (L8). Run it after every
change; `DRIFT DETECTED` is the only failure mode, and it is loud.
