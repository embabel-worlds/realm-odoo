import { Entity } from "@embabel/runtime-types";
import { activityArgs, odooDateTime, odooId, type FollowUp, type OdooWriteGateway } from "./odoo";

export interface CallBooking {
  /** What the meeting is called in the calendar. */
  title: string;
  /** When it starts, as an ISO date-time; read as UTC when it carries no offset. */
  start: string;
  /** How long it lasts. Defaults to 30 minutes. */
  minutes?: number;
  /** Agenda or context, shown on the event. */
  description?: string;
  /**
   * Whether Odoo emails the customer an invitation. Defaults to false: an invitation cannot be
   * recalled, so sending one is something a caller asks for, never something that happens to it.
   */
  sendInvitation?: boolean;
}

/**
 * A customer in Odoo (`res.partner`), with what can be done to it from wherever it was found:
 * reached by a view, by a traversal from an invoice, or from the vocabulary's CrmAccount.
 *
 * The method names are the ones any CRM realm offers on its customer, so code written against one
 * stack reads the same against another.
 */
export class OdooCustomer extends Entity<OdooWriteGateway> {
  name?: string;
  email?: string;
  website?: string;


  /** Add an internal note to the customer's history. The customer never sees it; nobody is emailed. */
  async addNote(text: string): Promise<number> {
    const r = await this.gateway.odoo.partnerMessagePost({
      ids: [odooId(this.id)], body: text, message_type: "comment", subtype_xmlid: "mail.mt_note",
    });
    return Array.isArray(r) ? r[0] : r;
  }

  /** Schedule follow-up work on the customer, due on a date, optionally assigned to someone. */
  async scheduleFollowUp(followUp: FollowUp): Promise<number> {
    const ids = await this.gateway.odoo.partnerActivitySchedule(activityArgs(odooId(this.id), followUp));
    // A list of new ids when Odoo was called; anything else — a request a person must approve
    // first, when the agent may only ask — is passed back as it came, never read as an id.
    return Array.isArray(ids) ? ids[0] : ids;
  }

  /** Book a call with the customer in Odoo's calendar. No invitation is sent unless asked for. */
  async bookCall(call: CallBooking): Promise<number> {
    const start = new Date(/[zZ]|[+-]\d\d:?\d\d$/.test(call.start) ? call.start : `${call.start}Z`);
    if (Number.isNaN(start.getTime())) throw new Error(`start is not a date-time: '${call.start}'`);
    const stop = new Date(start.getTime() + (call.minutes ?? 30) * 60_000);
    const ids = await this.gateway.odoo.calendarEventCreate({
      vals_list: [{
        name: call.title,
        start: odooDateTime(start),
        stop: odooDateTime(stop),
        partner_ids: [[6, 0, [odooId(this.id)]]],
        ...(call.description ? { description: call.description } : {}),
      }],
      ...(call.sendInvitation ? {} : { context: { no_mail_to_attendees: true } }),
    });
    return ids[0];
  }
}
