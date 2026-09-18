#!/bin/bash
# First-boot for the demo Odoo. Idempotent: a second `up` finds the database and the key
# and does nothing. Runs as root only long enough to hand the volumes to the odoo user —
# a filestore written by root is one the server cannot read afterwards.
set -euo pipefail

DB=odoo
CONN=(--db_host "$PGHOST" --db_user "$PGUSER" --db_password "$PGPASSWORD")
chown -R odoo:odoo /var/lib/odoo /state

if psql -d "$DB" -tAc "select 1 from ir_module_module limit 1" >/dev/null 2>&1; then
  echo "init: database '$DB' already exists"
else
  # Odoo's own demo companies are on by default because this realm's test battery was
  # written against them. A stack that loads its own book turns them off: eleven invented
  # furniture dealers in the pipeline are noise in somebody else's story.
  DEMO=--with-demo; [ "${ODOO_DEMO_DATA:-true}" = false ] && DEMO=--without-demo=all
  echo "init: creating '$DB' with CRM, sales and invoicing ($DEMO)"
  runuser -u odoo -- odoo "${CONN[@]}" -d "$DB" -i base,crm,sale_management,account \
    $DEMO --stop-after-init --no-http
fi

if [ -s /state/odoo.env ]; then
  echo "init: API key already minted"
else
  echo "init: minting an API key for admin"
  # No expiry: a demo that stops working in three months is a demo nobody trusts.
  # sudo() is what permits the unbounded duration; with_user() is whose key it is.
  runuser -u odoo -- odoo shell "${CONN[@]}" -d "$DB" --no-http <<'PY'
admin = env.ref("base.user_admin")
key = env["res.users.apikeys"].with_user(admin).sudo()._generate("rpc", "account-health-demo", None)
env.cr.commit()
open("/state/odoo.env", "w").write(f"ODOO_API_KEY={key}\nODOO_LOGIN=admin\nODOO_PASSWORD=admin\n")
PY
  [ -s /state/odoo.env ] || { echo "init: key was not written" >&2; exit 1; }
fi
echo "init: done"
