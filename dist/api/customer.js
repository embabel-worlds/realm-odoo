"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.OdooCustomer = void 0;
const runtime_types_1 = require("@embabel/runtime-types");
const odoo_1 = require("./odoo");
/**
 * A customer in Odoo (`res.partner`), with what can be done to it from wherever it was found:
 * reached by a view, by a traversal from an invoice, or from the vocabulary's CrmAccount.
 *
 * The method names are the ones any CRM realm offers on its customer, so code written against one
 * stack reads the same against another.
 */
class OdooCustomer extends runtime_types_1.Entity {
    name;
    email;
    website;
    get api() {
        return this.gateway;
    }
    /** Add an internal note to the customer's history. The customer never sees it; nobody is emailed. */
    async addNote(text) {
        const r = await this.api.odoo.partnerMessagePost({
            ids: [(0, odoo_1.odooId)(this.id)], body: text, message_type: "comment", subtype_xmlid: "mail.mt_note",
        });
        return Array.isArray(r) ? r[0] : r;
    }
    /** Schedule follow-up work on the customer, due on a date, optionally assigned to someone. */
    async scheduleFollowUp(followUp) {
        const ids = await this.api.odoo.partnerActivitySchedule((0, odoo_1.activityArgs)((0, odoo_1.odooId)(this.id), followUp));
        return ids[0];
    }
    /** Book a call with the customer in Odoo's calendar. No invitation is sent unless asked for. */
    async bookCall(call) {
        const start = new Date(/[zZ]|[+-]\d\d:?\d\d$/.test(call.start) ? call.start : `${call.start}Z`);
        if (Number.isNaN(start.getTime()))
            throw new Error(`start is not a date-time: '${call.start}'`);
        const stop = new Date(start.getTime() + (call.minutes ?? 30) * 60_000);
        const ids = await this.api.odoo.calendarEventCreate({
            vals_list: [{
                    name: call.title,
                    start: (0, odoo_1.odooDateTime)(start),
                    stop: (0, odoo_1.odooDateTime)(stop),
                    partner_ids: [[6, 0, [(0, odoo_1.odooId)(this.id)]]],
                    ...(call.description ? { description: call.description } : {}),
                }],
            ...(call.sendInvitation ? {} : { context: { no_mail_to_attendees: true } }),
        });
        return ids[0];
    }
}
exports.OdooCustomer = OdooCustomer;
