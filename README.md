# realm-odoo

Odoo Community, spoken to through its OWN middle tier — the JSON-2 API, never the database —
as an Embabel realm: typed virtual entities over live CRM, sales and invoicing data, curated
views that answer the questions people actually type, a natural-language surface that routes to
those views, an app with per-record links back into Odoo, and a shipped regression battery that
reconciles every figure against the source.

**[How it works](HOW-IT-WORKS.md)** — the mechanism layer by layer, with the actual queries.

The demo sentence, answered across modules no Odoo screen composes:

> Which customers have an open opportunity — and what do they still owe us?

Odoo's own AI (Enterprise-only, credit-metered) is a read-only, per-module assistant. This
realm answers cross-module with exact figures on the Community edition, every entity linked to
its Odoo record, and ships the tests that prove the numbers.

## What's inside

- `types/` — `OdooLead`, `OdooCustomer`, `OdooInvoice`, `OdooOrder`, plus two DOORS:
  `OdooStagePipeline` (pinned by stage name) and `OdooBook` (identity default `all`, so an
  unpinned `MATCH (b:OdooBook)` self-pins — generators and humans write anchors bare).
  Every relation is declared from what the ORM itself states; nothing is guessed.
- `producers/` — `search_read` through JSON-2 with domain pushdown. Conventions that were
  each learned the hard way, and commented where they live: `load: ""` (bare ids for joins),
  `keyType: int` (Odoo matches nothing on string ids, silently), `echoKeyAs` (join-safe
  attribution), partnerless leads filtered (Odoo spells "no partner" as `false`).
- `views/` — the answer surface: receivables per customer, outstanding invoices, open
  pipeline (probability-filterable), wins (date-windowable), customer count. Aggregation and
  identity-keyed dedupe live HERE, tested once. Every entity column travels with its id.
  Cross-realm views join the book to Diffbot firmographics (debtor ownership — "who
  ultimately owns the companies that owe us money") and to live news, gated through the
  Diffbot hop so a fictional customer never attracts a real company's headlines. And
  `OdooMeetingBriefing` is the AI layer in-query: one Virtual Cypher statement walks meeting
  → attendees → debt → deals → chatter → firmographics → news and `synthesize()`s a briefing
  per meeting, exact figures beside the prose.
- `lenses/deal-triage.yml` — classification where one query can't judge: every open deal
  triaged strategic/standard/at_risk, sentiment read from its own chatter thread.
- `seed/` — a demo book of REAL companies with fictional debts, deals, chatter arcs and
  meetings, created through Odoo's own API; gated, idempotent, removable.
- `apps/whole-customer.*` — pipeline × receivables per customer in Odoo's visual idiom, with
  an AI read grounded on each card's rows, an Ask box showing the generated Virtual Cypher,
  and the `<x>Id` linking convention: names jump to cards or open the record in Odoo.
- `skills/odoo-extension/` — teaches a coding agent to extend this realm for a customer's
  custom modules by reading `fields_get` through the realm's own API.
- `tests/` — `questions.yml` (the natural-language battery; money and counts assert
  `matchesView`, reconciling the NL answer against the curated view) and `verify.sh`
  (ground truth from Odoo directly → traversals → views → battery, exact equality, one
  command). Add every question that ever disappoints you; each becomes permanent.

## Setup

1. An Odoo 19+ instance with the JSON-2 API (`/json/2/<model>/<method>`). For a demo:
   the official `odoo:19` image + Postgres, database created with demo data.
2. An API key for the connecting user (Settings → Users → API Keys; scope `rpc`).
3. `ODOO_API_KEY` in the appliance's environment. On the Docker appliance, put it in
   `secrets.env` beside the compose file (see `secrets.env.example` there) — the compose
   passes that whole file into the container, so no compose edit is needed.
4. The server URL in `apis/odoo-json2.json` (`servers[0].url`) is the one install-specific
   fact here — point it at your Odoo as the APPLIANCE reaches it
   (`host.docker.internal:8069` for a host-local demo). `apps/whole-customer.js` carries the
   browser-reachable twin (`ODOO_BASE`) for record deep links.
5. Install by reference from the appliance's realms mount (`install_realm_from_path`), then
   `realm_refresh` after edits.

## Verify before anyone asks it anything

    ODOO=http://127.0.0.1:8069 ODOO_KEY=<key> \
    APPLIANCE=http://127.0.0.1:4342 AUTH=<user:pass> \
    sh tests/verify.sh

Green means: figures reconcile against Odoo to the cent, every view answers with every
parameter, and all sixteen battery questions pass — money ones equal to their views.

## Honest ledger

- **Verified live**: everything above, against Odoo 19 (2026-08) demo data — including the
  battery, the app's data calls, and the record deep links (`/odoo/<model>/<id>`).
- **Read-only by design (v1)**: no `create`/`write` verbs yet. When they come, they go
  through the API — record rules, chatter and computed fields are ORM-enforced, and a write
  around the middle tier is a defect, not a shortcut.
- **Known boundaries**: leads without a partner are excluded from partner-joined doors
  (Odoo spells "no partner" as `false`; the engine now drops such keys at the seam, and the
  producer's domain filter also skips the wasted fetch); Odoo demo data genuinely contains duplicate
  invoice NAMES with distinct ids — everything here keys on ids, which is why that is
  visible rather than silently merged.

## License

Apache-2.0.
