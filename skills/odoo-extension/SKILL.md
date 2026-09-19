---
name: odoo-extension
description: Extend realm-odoo for a customer's actual Odoo install — custom modules, studio fields, extra models — by reading the install's own metadata through the realm's API and writing the additional types, joins and producers. Use when a question needs an Odoo model this realm does not yet type, or when a customer's install carries customizations.
---

Odoo describes itself. Every install can be asked what models and fields it ACTUALLY has —
customizations included — through the same API this realm already speaks. Extending the realm is
therefore mechanical: read the metadata, write the YAML, refresh, prove it with a query.

## 1. Ask the install what exists

`fields_get` on any model returns, per field: the human label (`string`), the `type`, the
declared `relation` for many2one/one2many/many2many, `help` text, and `selection` values.
Through the realm's API it is the `fieldsGet` operation; only ask for what you need:

    POST /json/2/<model>/fields_get
    {"attributes": ["string", "type", "relation", "help", "selection"]}

To discover models rather than fields, `search_read` on `ir.model` with a domain like
`[["model", "like", "x_"]]` (studio models) or by module. 424 models exist on a modest install —
never type them all; type what the question needs.

## 2. Shear the chatter before you type anything

Every Odoo model drags the mail framework behind it: `message_ids`, `message_follower_ids`,
`activity_*`, `website_message_ids`, `rating_ids`. On crm.lead that is dozens of a hundred-plus
fields. None of it belongs in a type. Take the business fields: the ones whose labels a person
at the customer would recognize.

## 3. Write what the ORM declared — never guess

A `many2one` with `relation: res.partner` IS the virtual join: keyField = the field (bare id via
`load: ""`), recordKeyField = `id` on the target, producer = a `search_read` keyed
`["id", "in", []]`. Follow the shapes in `types/odoo.yml` and `producers/odoo.yml` exactly —
including `load: ""` on every producer, which is load-bearing: without it many2one fields arrive
as `[id, name]` pairs and every join silently matches nothing.

New operations (a new model's `search_read`) are added to `apis/odoo-json2.json` as their own
path — copy an existing one, change the model segment and operationId.

**Declare the filters the domain can express (`pushdown:`).** A domain is a list of triples and no
text template can build one, so use `argPath` + `clause`. `domain.-` APPENDS, which is what keeps
an existing `keyArg: "domain.0.2"` pointing at the triple it always did — a domain is an implicit
conjunction, so nothing links to the clause before it and no `linkPrevious` is needed.

```yaml
pushdown:
  - property: state
    op: IN
    argPath: domain.-
    clause: ["state", "in", "{values}"]
```

This is not a micro-optimisation. Without it a `WHERE` is applied to the graph after every record
has been fetched, and — because what the source absorbs is what licenses the engine to push a
`LIMIT` or ask for a `count()` instead of the records — an undeclared filter costs a call per
anchor, not just a page. A `search_read` that can take the triple should be given it.

Prove it the way you prove everything else here: run the question and look at the call count, not
at the fact that the rule parsed.

## 4. Refresh, then prove it with the question

`realm_refresh`, then run the actual question the extension exists to answer, through
`kg_query`, and get rows. `realm_status` saying active is not the proof; rows are. A domain
filter inside a producer (a payment_state, a move_type) is a judgment call — state it in a
comment where a reviewer will find it.

## What not to do

- Do not read or write the database. Structure and permissions live in the ORM; the API is the
  only door this realm uses, and a write bypassing it skips validation, record rules and chatter.
- Do not type models wholesale. A realm surface is curated; 424 models is an install, not a realm.
- Do not invent field meanings — `help` text exists; quote it.
