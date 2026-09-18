#!/usr/bin/env python3
"""Load the CRM part of a neutral book into Odoo, through Odoo's own JSON-2 API.

A BOOK is a directory of product-neutral CSVs (crm/, support/, billing/) joined by
`account_key`, the customer's domain. This loader reads only crm/ and knows only Odoo; it
has never heard of the product the data was authored for. That split is what makes loading
reusable: a new dataset needs one converter to the book, a new product needs one of these.

    ODOO_API_KEY=... ./load_book.py --book ~/dev/sample-business-data/book --yes
    ODOO_API_KEY=... ./load_book.py --book ... --remove --yes      # undo a previous load

It follows the realm spec's rules for seeds. It refuses to run without --yes, because the
difference between a demo Odoo and a real one is one URL. It is idempotent: every record
is looked up before it is made, and a second run changes nothing. And what it makes is
recognizable — partners carry the reference BOOK-<source id> — so it can be listed and
removed. It never touches the database: a record Odoo's own rules would refuse is a record
this loader cannot create, which is the point.

What the book says and Odoo cannot hold is said in the report at the end, not dropped
quietly. The main one is age: Odoo stamps records when they are made, so created-on dates
survive only where Odoo has a field of its own for them.
"""

import argparse
import csv
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

MARK = "BOOK-"
PRIORITY = {"low": "1", "medium": "2", "high": "3"}


class Odoo:
    def __init__(self, url, key):
        self.url, self.key = url.rstrip("/"), key

    def call(self, model, method, **payload):
        req = urllib.request.Request(
            f"{self.url}/json/2/{model}/{method}", data=json.dumps(payload).encode(),
            headers={"Authorization": f"Bearer {self.key}", "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")
            try:
                detail = json.loads(detail).get("message", detail)
            except ValueError:
                pass
            raise SystemExit(f"Odoo refused {model}.{method}: {detail[:500]}")

    def find(self, model, domain, fields=("id",)):
        rows = self.call(model, "search_read", domain=domain, fields=list(fields), load="", limit=1,
                         context={"active_test": False})
        return rows[0] if rows else None

    def ensure(self, model, domain, vals):
        """The id of the record matching `domain`, created from `vals` if there is none."""
        found = self.find(model, domain)
        if found:
            return found["id"], False
        return self.call(model, "create", vals_list=[vals])[0], True


def rows(book, name):
    with open(book / name, newline="") as f:
        return list(csv.DictReader(f))


def load(odoo, book):
    made = {"salespeople": 0, "accounts": 0, "contacts": 0, "opportunities": 0, "notes": 0}
    accounts, contacts, deals = rows(book, "crm/accounts.csv"), rows(book, "crm/contacts.csv"), rows(book, "crm/opportunities.csv")

    # Owners become real Odoo users so the pipeline is somebody's, and so a note can be
    # written in the voice of the person the book says wrote it. no_reset_password: a fresh
    # user otherwise triggers an invitation email to an address that does not exist.
    users = {}
    for name in sorted({r["owner"] for r in accounts + contacts + deals if r["owner"]}):
        login = name.lower().replace(" ", ".") + "@vendor.example"
        uid, new = odoo.ensure("res.users", [["login", "=", login]], {"name": name, "login": login})
        made["salespeople"] += new
        users[name] = (uid, odoo.find("res.users", [["id", "=", uid]], ["partner_id"])["partner_id"])

    def note(model, rid, text, who, when):
        if not text:
            return
        # A note, not a message: mt_note stays internal, where a comment could be emailed
        # to followers. Dated when the book says it was written — Odoo allows that here.
        odoo.call(model, "message_post", ids=[rid], body=text, message_type="comment",
                  subtype_xmlid="mail.mt_note", author_id=users[who][1] if who in users else False,
                  date=f"{when} 09:00:00" if when else False)
        made["notes"] += 1

    countries, states, industries = {}, {}, {}

    def country(name):
        if name and name not in countries:
            hit = odoo.find("res.country", [["name", "=", name]])
            countries[name] = hit["id"] if hit else False
        return countries.get(name, False)

    def state(code, country_id):
        if code and country_id and (code, country_id) not in states:
            hit = odoo.find("res.country.state", [["code", "=", code], ["country_id", "=", country_id]])
            states[(code, country_id)] = hit["id"] if hit else False
        return states.get((code, country_id), False)

    company = {}
    for a in accounts:
        if a["industry"] not in industries:
            industries[a["industry"]] = odoo.ensure("res.partner.industry", [["name", "=", a["industry"]]], {"name": a["industry"]})[0]
        cid = country(a["country"])
        facts = f"Annual revenue {a['annual_revenue']} · {a['employees']} employees · domain {a['account_key']}"
        pid, new = odoo.ensure("res.partner", [["ref", "=", MARK + a["source_id"]]], {
            "name": a["name"], "is_company": True, "ref": MARK + a["source_id"], "website": a["website"],
            "phone": a["phone"], "city": a["city"], "country_id": cid, "state_id": state(a["region"], cid),
            "industry_id": industries[a["industry"]], "user_id": users[a["owner"]][0],
            "customer_rank": 1 if a["relationship"] == "customer" else 0, "comment": facts})
        company[a["account_key"]] = pid
        if new:
            made["accounts"] += 1
            note("res.partner", pid, a["note"], a["owner"], a["created_on"])

    for c in contacts:
        cid = country(c["country"])
        pid, new = odoo.ensure("res.partner", [["ref", "=", MARK + c["source_id"]]], {
            "name": f"{c['first_name']} {c['last_name']}", "is_company": False, "ref": MARK + c["source_id"],
            "parent_id": company[c["account_key"]], "email": c["email"], "phone": c["phone"],
            "function": c["job_title"], "city": c["city"], "country_id": cid,
            "state_id": state(c["region"], cid), "user_id": users[c["owner"]][0]})
        if new:
            made["contacts"] += 1
            note("res.partner", pid, c["note"], c["owner"], c["last_activity_on"])

    # The book's pipeline steps become Odoo stages, in the book's order. Won is Odoo's own
    # stage (it carries is_won, which reporting depends on); lost is not a stage in Odoo at
    # all but an archived lead, so neither is created here.
    stages = {}
    for d in deals:
        if d["status"] == "open" and d["stage"] not in stages:
            stages[d["stage"]] = odoo.ensure("crm.stage", [["name", "=", d["stage"]]],
                                             {"name": d["stage"], "sequence": 10 * int(d["stage_order"])})[0]
    # Odoo's stock steps would sit empty beside the book's. Folded, not deleted: they are
    # one click from coming back, and nothing of the user's is destroyed.
    stock = odoo.call("crm.stage", "search_read", domain=[["name", "in", ["New", "Qualified", "Proposition"]]], fields=["id"], load="")
    for s in stock:
        if not odoo.find("crm.lead", [["stage_id", "=", s["id"]]]):
            odoo.call("crm.stage", "write", ids=[s["id"]], vals={"fold": True})

    teams, tags = {}, {}
    for d in deals:
        if d["pipeline"] not in teams:
            teams[d["pipeline"]] = odoo.ensure("crm.team", [["name", "=", d["pipeline"]]], {"name": d["pipeline"]})[0]
        if d["kind"] not in tags:
            tags[d["kind"]] = odoo.ensure("crm.tag", [["name", "=", d["kind"]]], {"name": d["kind"]})[0]
        partner = company[d["account_key"]]
        person = next(c for c in contacts if c["email"] == d["contact_email"])
        vals = {"name": d["title"], "type": "opportunity", "partner_id": partner,
                "contact_name": f"{person['first_name']} {person['last_name']}", "email_from": person["email"],
                "function": person["job_title"], "expected_revenue": float(d["amount"]),
                "date_deadline": d["close_on"], "user_id": users[d["owner"]][0], "team_id": teams[d["pipeline"]],
                "priority": PRIORITY[d["priority"]], "tag_ids": [[6, 0, [tags[d["kind"]]]]],
                "description": d["note"]}
        if d["status"] == "open":
            vals["stage_id"] = stages[d["stage"]]
        lid, new = odoo.ensure("crm.lead", [["name", "=", d["title"]], ["partner_id", "=", partner]], vals)
        if not new:
            continue
        made["opportunities"] += 1
        if d["status"] == "won":
            odoo.call("crm.lead", "action_set_won", ids=[lid])
        elif d["status"] == "lost":
            odoo.call("crm.lead", "action_set_lost", ids=[lid])
        else:
            # Written last, on its own: Odoo recomputes probability whenever the stage
            # moves, and a value written alongside the stage is the one that loses.
            odoo.call("crm.lead", "write", ids=[lid], vals={"probability": 100 * float(d["probability"])})
        note("crm.lead", lid, d["note"], d["owner"], d["modified_on"])
    return made


def remove(odoo):
    partners = [p["id"] for p in odoo.call("res.partner", "search_read", domain=[["ref", "=like", MARK + "%"]],
                                           fields=["id"], load="", context={"active_test": False})]
    leads = [l["id"] for l in odoo.call("crm.lead", "search_read", domain=[["partner_id", "in", partners]],
                                        fields=["id"], load="", context={"active_test": False})]
    if leads:
        odoo.call("crm.lead", "unlink", ids=leads)
    if partners:
        odoo.call("res.partner", "unlink", ids=partners)
    print(f"removed {len(leads)} opportunities and {len(partners)} partners. Salespeople, stages, "
          f"teams and tags are left: they are configuration, and other records may now use them.")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--book", required=True, type=Path, help="directory holding crm/accounts.csv and friends")
    ap.add_argument("--url", default=os.environ.get("ODOO_URL", "http://127.0.0.1:8069"))
    ap.add_argument("--remove", action="store_true", help="delete what a previous load created")
    ap.add_argument("--yes", action="store_true", help="confirm that the target is disposable")
    args = ap.parse_args()
    key = os.environ.get("ODOO_API_KEY") or sys.exit("ODOO_API_KEY is not set")
    if not args.yes:
        sys.exit(f"This would write into {args.url} — a system you must consider disposable.\nRe-run with --yes to proceed.")
    odoo = Odoo(args.url, key)
    if args.remove:
        return remove(odoo)
    made = load(odoo, args.book)
    print("odoo: created " + ", ".join(f"{n} {what}" for what, n in made.items()) if any(made.values())
          else "odoo: everything in the book was already there; nothing changed")
    print("odoo: not carried — created-on dates of accounts, contacts and opportunities (Odoo stamps its own);\n"
          "      annual revenue and headcount have no CRM field and are in each company's internal notes.")


if __name__ == "__main__":
    main()
