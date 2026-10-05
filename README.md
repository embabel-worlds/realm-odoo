# realm-odoo

Odoo Community, spoken to through its OWN middle tier — the JSON-2 API, never the database —
as an Embabel realm: typed virtual entities over live CRM, sales and invoicing data, curated
views that answer the questions people actually type, a natural-language surface that routes to
those views, an app with per-record links back into Odoo, and a shipped regression battery that
reconciles every figure against the source.

**[What you can ask it](EXAMPLES.md)** — real questions, where each answer comes from, and the
verbatim answers from the demo book.
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
  Diffbot hop so a fictional customer never attracts a real company's headlines. And two
  views carry the AI layer in-query: `OdooMeetingBriefing` walks meeting → attendees → debt
  → deals → chatter → firmographics → news in one Virtual Cypher statement and
  `synthesize()`s a briefing per meeting; `OdooDealTriage` `classify()`s every open deal
  strategic/standard/at_risk (filterable, so "which deals are at risk" binds it) and reads
  sentiment from each deal's own chatter thread. Exact figures travel beside the labels and
  prose in both.
- `seed/` — a demo book of REAL companies with fictional debts, deals, chatter arcs and
  meetings, created through Odoo's own API; gated, idempotent, removable. `seed/load_book.py`
  also loads a book's manual history when it has one — `crm/notes.csv`, back-dated in their
  authors' names, and `crm/meetings.csv` as calendar events, invitations suppressed.
- `apps/prospect.*` — pipeline × receivables per customer in Odoo's visual idiom, with
  an AI read grounded on each card's rows, an Ask box showing the generated Virtual Cypher,
  and the `<x>Id` linking convention: names jump to cards or open the record in Odoo. The
  intelligence views land here too: meeting briefings above the cards, triage and sentiment
  pills on each open deal — arriving after the figures, never delaying them.
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
   (`host.docker.internal:8069` for a host-local demo). Odoo's BROWSER address is the
   other, and it is written in two places: `ODOO_BASE` in `apps/prospect.js`, and the
   `sourceUrl` compute on the five partner doors in `producers/odoo.yml`
   (`http://localhost:8069` for the demo). A query's `sourceUrl`, and the
   `CustomerAccount.sourceUrl` filled from it, open the record only if it is right.
5. Install by reference from the appliance's realms mount (`install_realm_from_path`), then
   `realm_refresh` after edits.

## Verify before anyone asks it anything

    ODOO=http://127.0.0.1:8069 ODOO_KEY=<key> \
    APPLIANCE=http://127.0.0.1:4342 AUTH=<user:pass> \
    sh tests/verify.sh

Green means: figures reconcile against Odoo to the cent, every view answers with every
parameter, and all sixteen battery questions pass — money ones equal to their views.

## Working on what you find

A customer or a deal found by a query can be worked on where it is found. `OdooCustomer` and
`OdooLead` carry methods, written in TypeScript in `src/api/`:

| Type | Method | Does |
|---|---|---|
| `OdooCustomer` | `addNote(text)` | an internal note in the customer's history; nobody is emailed |
| | `scheduleFollowUp({summary, due, note?, assigneeUserId?, kind?})` | a to-do or a call to make, due on a date |
| | `bookCall({title, start, minutes?, description?, sendInvitation?})` | a meeting with the customer; no invitation unless asked |
| `OdooLead` | `scheduleFollowUp(...)` | the same, on a deal |
| | `update(fields)` | overwrites fields on the deal |

```js
const { rows } = await gateway.cypher.query({ cypher: `
  MATCH (b:OdooBook)-[:HAS_CUSTOMER]->(c:OdooCustomer) WHERE c.name = 'Acme Corporation' RETURN c` });
state.set("acme", rows[0].c);                       // bound with its type's methods
const acme = state.get("acme");
await acme.addNote("Second failed payment this month; chasing.");
await acme.bookCall({ title: "Payment review", start: "2026-10-20T15:00:00" });
```

Read with `gateway.cypher.query`, whose rows keep their type; `gateway.kg.query` returns plain
rows for answering questions. Each method calls exactly one of the write verbs below, so what can
change in Odoo is what `apis/odoo-json2.json` declares. To change a method: edit `src/api/`,
`npm test`, `npm run build`, and commit `dist/` with it.

## Honest ledger

- **Verified live**: everything above, against Odoo 19 (2026-08) demo data — including the
  battery, the app's data calls, and the record deep links (`/odoo/<model>/<id>`).
- **Writes, through the API only**: five verbs, each Odoo's own method on the record, so record
  rules, chatter and computed fields stay ORM-enforced; a write around the middle tier would be
  a defect, not a shortcut.
  - `partnerMessagePost`: an internal note on a customer. It never emails anyone.
  - `partnerActivitySchedule` and `leadActivitySchedule`: a to-do on a customer or a deal, due on
    a date and optionally assigned to someone.
  - `calendarEventCreate`: a meeting, such as a call with the customer. Pass
    `context: {no_mail_to_attendees: true}` to book it without sending invitations.
  - `leadWrite`: overwrite fields on an opportunity. It exists so a world can see it and refuse
    it; nothing in this realm needs it.

  Each declares, as `x-embabel-effect` in `apis/odoo-json2.json`, what it changes, whether and how
  it can be undone, and which arguments identify a repeat. The host reads it: an observing agent is
  refused every declared write, and `calendarEventCreate` is `sensitive` (its invitations go to the
  attendees), so an agent is asked for approval before creating an event even when it may act.
  The three that leave text people read — a note's `body`, an activity's `note` — name it as
  `attribution`, so a note an agent writes says who wrote it: "— via Chaser, for Priya" on its
  sponsor's account, "— Chaser (an agent)" on its own.
  `tests/verify-writes.sh` calls every verb through the appliance, reconciles the result against
  Odoo, and undoes it; `verify.sh` runs it only with `VERIFY_WRITES=1`.
- **Known boundaries**: leads without a partner are excluded from partner-joined doors
  (Odoo spells "no partner" as `false`; the engine now drops such keys at the seam, and the
  producer's domain filter also skips the wasted fetch); Odoo demo data genuinely contains duplicate
  invoice NAMES with distinct ids — everything here keys on ids, which is why that is
  visible rather than silently merged.

## License

Apache-2.0.
