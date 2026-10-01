/*
 * The slice of the gateway these types call: the realm's own write verbs (apis/odoo-json2.json),
 * typed here because the generated surface types the gateway loosely.
 */

export interface FollowUp {
  /** What needs doing, as it will read in the assignee's list. */
  summary: string;
  /** The due date, `YYYY-MM-DD`. */
  due: string;
  /** More detail, shown with the activity. */
  note?: string;
  /** The Odoo user it is assigned to. Without one the activity is unassigned. */
  assigneeUserId?: number;
  /** A to-do, or a call to make. Defaults to a to-do. */
  kind?: "todo" | "call";
}

export interface OdooWriteGateway {
  odoo: {
    partnerMessagePost(args: { ids: number[]; body: string; message_type: "comment"; subtype_xmlid: "mail.mt_note" }): Promise<number | number[]>;
    partnerActivitySchedule(args: ActivityArgs): Promise<number[]>;
    leadActivitySchedule(args: ActivityArgs): Promise<number[]>;
    calendarEventCreate(args: {
      vals_list: { name: string; start: string; stop: string; partner_ids?: unknown[]; description?: string }[];
      context?: Record<string, unknown>;
    }): Promise<number[]>;
    leadWrite(args: { ids: number[]; vals: Record<string, unknown> }): Promise<boolean>;
  };
}

interface ActivityArgs {
  ids: number[];
  summary: string;
  date_deadline: string;
  note?: string;
  user_id?: number;
  act_type_xmlid?: string;
}

/** A follow-up in the arguments Odoo's `activity_schedule` takes, for one record. */
export function activityArgs(id: number, f: FollowUp): ActivityArgs {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(f.due)) throw new Error(`due must be YYYY-MM-DD, got '${f.due}'`);
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
export function odooDateTime(d: Date): string {
  return d.toISOString().replace("T", " ").slice(0, 19);
}

/** The record's Odoo id. The graph carries ids as strings; Odoo's own are integers. */
export function odooId(id: unknown): number {
  const n = Number(id);
  if (!Number.isInteger(n) || n <= 0) throw new Error(`not an Odoo record id: '${String(id)}'`);
  return n;
}
