# What you can ask it

Real questions against the demo book — each with where the answer comes from and what came
back, verbatim, from the seeded demo (`seed/`: real companies, fictional debts). Every figure
here is reconciled against Odoo directly by `tests/verify.sh`; every question lives in
`tests/questions.yml` as a permanent regression test. Ask these through the chat, the
`/api/v1/admin/kg/ask` endpoint, or the whole-customer app's Ask box.

## The book itself

> **How many customers do we have?**
> → view `OdooCustomerCount` — **9**

> **Which customers owe us most money?**
> → view `OdooReceivablesByCustomer` — Acme Corporation, **$193,281.25** across 6 unpaid
> invoices; then Atlassian $84,000, Azure Interior $63,500, Qantas $52,750…

> **What are the 10 biggest outstanding invoices?**
> → view `OdooOutstandingInvoices` — top: Atlassian's SEED-ATL-1, **$84,000**, every row
> carrying its `invoiceId` so the app links straight into Odoo.

> **What was our biggest win this quarter?**
> → view `OdooWins`, the selector computing the calendar window from today —
> Distributor Contract (Gemini Furniture), **$19,800**.

> **What was our biggest win of the last quarter?**
> → the same view, previous window — **no rows**, and that is the correct answer: every
> demo win closed this quarter. An honest empty beats a confident wrong figure; the battery
> asserts this one stays empty.

## Filtered forms

> **What are our 10 biggest opportunities over 60%?**
> → view `OdooOpenPipeline` with `minProbability: 60` — SEED Team workflow rollout
> (Atlassian), **$120,000 at 65%**. The selector refuses to drop a stated constraint: a view
> that cannot express "over 60%" is not selected for this question.

## The book joined to the real world (realm-diffbot)

> **How big are our customers?**
> → view `OdooCustomerFirmographics` — Bunnings **53,000** employees, Qantas 21,000,
> Atlassian 12,000, Canva 5,500, Neo4j 862. Customers with placeholder domains are absent —
> absence is the honest answer, not a failure.

> **Who ultimately owns the companies that owe us money?**
> → view `OdooDebtorOwnership` — Bunnings owes **$22,000** and is ultimately owned by
> **Wesfarmers**. An invoice to a subsidiary is exposure to the parent; no Odoo screen can
> compose this.

> **What industries do we sell into?**
> → generation over the firmographics join — Software, Airlines, Retailers, Hardware
> Stores, Database Companies.

## Live news (realm-research)

> **What's in the news about the companies that owe us money?**
> → view `OdooDebtorNews` — hours-old headlines per debtor: a Qantas A380 maintenance
> incident, Atlassian insider stock sales. Gated through the Diffbot hop, so a fictional
> customer's name never attracts a real company's headlines.

## Judgment (the AI layer)

> **Which of our deals are at risk?**
> → lens `deal-triage` (provenance says so: no single query exists) — Atlassian's $120k
> deal at 65% is **at_risk**: its own chatter thread reads negative (pricing pushback,
> legal stalled three weeks, champion gone quiet). The judgment outweighs the optimistic
> probability field — which is the point.

> **How do our open opportunities feel?**
> → the same lens — sentiment per deal read from what participants actually wrote,
> including a French email thread correctly read as positive.

## Meeting preparation

> **Prep me for my meeting with Qantas.**
> → view `OdooMeetingBriefing` — one Virtual Cypher query walks meeting → attendees →
> debt → deals → chatter → firmographics → news and `synthesize()`s the briefing in-query.
> Exact figures travel beside the prose and reconcile to the cent. The Atlassian one:

> *"They currently owe us $84,000 on one unpaid invoice. The open deal for the SEED Team
> workflow rollout is valued at $120,000 with a 65% chance of closing, but recent pricing
> pushback from procurement indicates they want a 20% discount or will pause the deal.
> Legal review has been stalled for three weeks… Meanwhile, Atlassian's stock has soared
> amid AI and cloud growth, but the recent sale of $1.2 million stock by the chief revenue
> officer could signal internal caution. The key point to raise is the need to clarify
> pricing conditions and realign the deal amidst the legal delays."*

Debt from Odoo, odds from CRM, mood from chatter, market signal from live news, ownership
from a knowledge graph — one paragraph no single system could have written.

## Adding your own

Every question that ever disappoints you belongs in `tests/questions.yml` — with a
`matchesView` assertion if it is about money or counts — where it becomes a permanent
regression test. If a phrasing routes wrongly, add it to the description of the view that
should have answered it: the view's description IS the routing vocabulary. See
[HOW-IT-WORKS.md](HOW-IT-WORKS.md) for the mechanism.
