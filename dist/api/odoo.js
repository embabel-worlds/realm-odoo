"use strict";
/*
 * The slice of the gateway these types call: the realm's own write verbs (apis/odoo-json2.json),
 * typed here because the generated surface types the gateway loosely.
 */
Object.defineProperty(exports, "__esModule", { value: true });
exports.activityArgs = activityArgs;
exports.odooDateTime = odooDateTime;
exports.odooId = odooId;
/** A follow-up in the arguments Odoo's `activity_schedule` takes, for one record. */
function activityArgs(id, f) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(f.due))
        throw new Error(`due must be YYYY-MM-DD, got '${f.due}'`);
    return {
        ids: [id],
        summary: f.summary,
        date_deadline: f.due,
        ...(f.note ? { note: f.note } : {}),
        ...(f.assigneeUserId ? { user_id: f.assigneeUserId } : {}),
        act_type_xmlid: f.kind === "call" ? "mail.mail_activity_data_call" : "mail.mail_activity_data_todo",
    };
}
/** Odoo stores datetimes in UTC as `YYYY-MM-DD HH:MM:SS`. */
function odooDateTime(d) {
    return d.toISOString().replace("T", " ").slice(0, 19);
}
/** The record's Odoo id. The graph carries ids as strings; Odoo's own are integers. */
function odooId(id) {
    const n = Number(id);
    if (!Number.isInteger(n) || n <= 0)
        throw new Error(`not an Odoo record id: '${String(id)}'`);
    return n;
}
