#!/bin/sh
# relentless-testing for realm-odoo's WRITE verbs: each one is called through the appliance's
# gateway, exactly as an agent's routine calls it, then reconciled against Odoo directly, then
# undone through Odoo directly so the seeded book is the same afterwards as before. A leg that
# writes and does not undo would leave the next reconciliation measuring this script, not the book.
#
#   ODOO=http://127.0.0.1:8069 ODOO_KEY=... APPLIANCE=http://127.0.0.1:11043 \
#     AUTH=user:pass sh tests/verify-writes.sh          (or APPLIANCE_TOKEN=... instead of AUTH)
set -e
ODOO="${ODOO:-http://127.0.0.1:8069}"
APPLIANCE="${APPLIANCE:-http://127.0.0.1:4342}"
: "${ODOO_KEY:?set ODOO_KEY}"
if [ -n "$APPLIANCE_TOKEN" ]; then set -- -H "Authorization: Bearer $APPLIANCE_TOKEN"
else : "${AUTH:?set AUTH (user:pass) or APPLIANCE_TOKEN}"; set -- -u "$AUTH"; fi

fail=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "  ok   $1 = $2"
  else echo "  FAIL $1: expected $2, got $3"; fail=1; fi
}
odoo() { # model method json
  curl -s -X POST "$ODOO/json/2/$1/$2" -H "Authorization: Bearer $ODOO_KEY" -H 'Content-Type: application/json' -d "$3"
}
# Through the appliance, the way a routine calls it. The auth flags are the positional parameters
# set above, passed through after the operation and body.
verb() { op=$1; body=$2; shift 2
  curl -s -X POST "$APPLIANCE/api/v1/tools/odoo_$op" "$@" -H 'Content-Type: application/json' -d "$body"
}
field() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

TAG="verify-writes-$(date +%s)"
PARTNER=$(odoo res.partner search_read '{"domain":[["customer_rank",">",0],["is_company","=",true]],"fields":["id"],"order":"id","limit":1}' | field "d[0]['id']")
LEAD=$(odoo crm.lead search_read '{"domain":[["type","=","opportunity"]],"fields":["id"],"order":"id","limit":1}' | field "d[0]['id']")
echo "== writes against customer $PARTNER and opportunity $LEAD, tagged $TAG =="

echo "-- partnerMessagePost: an internal note, never an email"
# message_post answers with the new message's id in a list, like every JSON-2 create.
MSG=$(verb partnerMessagePost "{\"ids\":[$PARTNER],\"body\":\"$TAG\",\"message_type\":\"comment\",\"subtype_xmlid\":\"mail.mt_note\"}" "$@" | field "(lambda r: r[0] if isinstance(r, list) else r)(d['result'])")
ROW=$(odoo mail.message search_read "{\"domain\":[[\"id\",\"=\",$MSG]],\"fields\":[\"res_id\",\"message_type\",\"subtype_id\"]}")
check "note is on the customer" "$PARTNER" "$(echo "$ROW" | field "d[0]['res_id']")"
check "note is a comment" "comment" "$(echo "$ROW" | field "d[0]['message_type']")"
check "note is internal" "Note" "$(echo "$ROW" | field "d[0]['subtype_id'][1]")"
odoo mail.message unlink "{\"ids\":[$MSG]}" >/dev/null

for KIND in partner lead; do
  if [ $KIND = partner ]; then ID=$PARTNER; MODEL=res.partner; else ID=$LEAD; MODEL=crm.lead; fi
  echo "-- ${KIND}ActivitySchedule: a to-do on the $KIND"
  ACT=$(verb ${KIND}ActivitySchedule "{\"ids\":[$ID],\"summary\":\"$TAG\",\"date_deadline\":\"2030-01-15\"}" "$@" | field "d['result'][0]")
  ROW=$(odoo mail.activity search_read "{\"domain\":[[\"id\",\"=\",$ACT]],\"fields\":[\"res_model\",\"res_id\",\"summary\",\"date_deadline\"]}")
  check "activity is on the $KIND" "$MODEL:$ID" "$(echo "$ROW" | field "d[0]['res_model']+':'+str(d[0]['res_id'])")"
  check "activity is due when asked" "2030-01-15" "$(echo "$ROW" | field "d[0]['date_deadline']")"
  odoo mail.activity unlink "{\"ids\":[$ACT]}" >/dev/null
done

echo "-- calendarEventCreate: a call booked with the customer, invitations suppressed"
EVT=$(verb calendarEventCreate "{\"vals_list\":[{\"name\":\"$TAG\",\"start\":\"2030-01-15 15:00:00\",\"stop\":\"2030-01-15 15:30:00\",\"partner_ids\":[[6,0,[$PARTNER]]]}],\"context\":{\"no_mail_to_attendees\":true}}" "$@" | field "d['result'][0]")
ROW=$(odoo calendar.event search_read "{\"domain\":[[\"id\",\"=\",$EVT]],\"fields\":[\"name\",\"start\",\"partner_ids\"]}")
check "event starts when asked" "2030-01-15 15:00:00" "$(echo "$ROW" | field "d[0]['start']")"
check "customer is an attendee" "True" "$(echo "$ROW" | field "$PARTNER in d[0]['partner_ids']")"
SENT=$(odoo mail.mail search_count "{\"domain\":[[\"subject\",\"ilike\",\"$TAG\"]]}")
check "no invitation was queued" "0" "$SENT"
odoo calendar.event unlink "{\"ids\":[$EVT]}" >/dev/null

echo "-- leadWrite: an overwrite, put back afterwards"
BEFORE=$(odoo crm.lead search_read "{\"domain\":[[\"id\",\"=\",$LEAD]],\"fields\":[\"description\"]}" | field "json.dumps(d[0]['description'])")
OK=$(verb leadWrite "{\"ids\":[$LEAD],\"vals\":{\"description\":\"$TAG\"}}" "$@" | field "d['result']")
check "write reported success" "True" "$OK"
# Each read is assigned before it is checked: inside a "$(...)" that is itself an argument in
# double quotes, the shell keeps the JSON's escaped quotes literally and Odoo receives backslashes.
AFTER=$(odoo crm.lead search_read "{\"domain\":[[\"id\",\"=\",$LEAD]],\"fields\":[\"description\"]}" | field "d[0]['description']" | sed 's/<[^>]*>//g')
check "lead carries the written value" "$TAG" "$AFTER"
odoo crm.lead write "{\"ids\":[$LEAD],\"vals\":{\"description\":$BEFORE}}" >/dev/null
RESTORED=$(odoo crm.lead search_read "{\"domain\":[[\"id\",\"=\",$LEAD]],\"fields\":[\"description\"]}" | field "json.dumps(d[0]['description'])")
check "lead is back as it was" "$BEFORE" "$RESTORED"

echo "-- nothing tagged is left behind"
N1=$(odoo mail.message search_count "{\"domain\":[[\"body\",\"ilike\",\"$TAG\"]]}")
N2=$(odoo mail.activity search_count "{\"domain\":[[\"summary\",\"=\",\"$TAG\"]]}")
N3=$(odoo calendar.event search_count "{\"domain\":[[\"name\",\"=\",\"$TAG\"]]}")
N4=$(odoo crm.lead search_count "{\"domain\":[[\"description\",\"ilike\",\"$TAG\"]]}")
LEFT=$((N1 + N2 + N3 + N4))
check "records left by this run" "0" "$LEFT"

exit $fail
