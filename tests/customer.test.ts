import { describe, it, expect, vi } from "vitest";
import { entityForTest, mockGateway } from "@embabel/runtime-types";
import type { OdooWriteGateway } from "../src/api/odoo";
import { OdooCustomer } from "../src/api/customer";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function customer(odoo: Record<string, (args: any) => any>, id: unknown = "12114") {
  return entityForTest(OdooCustomer, { id: id as string, name: "Acme Corporation" }, mockGateway<OdooWriteGateway>({ odoo }));
}

describe("OdooCustomer", () => {
  it("adds an internal note, never a comment that emails followers", async () => {
    const partnerMessagePost = vi.fn(async () => [54603]);
    expect(await customer({ partnerMessagePost }).addNote("Payment failed twice")).toBe(54603);
    expect(partnerMessagePost).toHaveBeenCalledWith({
      ids: [12114], body: "Payment failed twice", message_type: "comment", subtype_xmlid: "mail.mt_note",
    });
  });

  it("schedules a follow-up as a to-do unless asked for a call, assigned only when told who", async () => {
    const partnerActivitySchedule = vi.fn(async () => [7]);
    const c = customer({ partnerActivitySchedule });
    await c.scheduleFollowUp({ summary: "Chase the June invoice", due: "2026-10-15" });
    await c.scheduleFollowUp({ summary: "Call about renewal", due: "2026-10-16", kind: "call", assigneeUserId: 6, note: "60 days out" });
    expect(partnerActivitySchedule.mock.calls).toEqual([
      [{ ids: [12114], summary: "Chase the June invoice", date_deadline: "2026-10-15", act_type_xmlid: "mail.mail_activity_data_todo" }],
      [{ ids: [12114], summary: "Call about renewal", date_deadline: "2026-10-16", note: "60 days out", user_id: 6, act_type_xmlid: "mail.mail_activity_data_call" }],
    ]);
  });

  it("refuses a due date Odoo would misread", async () => {
    await expect(customer({}).scheduleFollowUp({ summary: "x", due: "15/10/2026" })).rejects.toThrow(/YYYY-MM-DD/);
  });

  it("books a call in UTC, half an hour by default, without an invitation unless asked", async () => {
    const calendarEventCreate = vi.fn(async () => [91]);
    const c = customer({ calendarEventCreate });
    expect(await c.bookCall({ title: "Renewal call", start: "2026-10-20T15:00:00" })).toBe(91);
    await c.bookCall({ title: "Escalation", start: "2026-10-20T10:00:00-04:00", minutes: 60, sendInvitation: true });
    expect(calendarEventCreate.mock.calls).toEqual([
      [{ vals_list: [{ name: "Renewal call", start: "2026-10-20 15:00:00", stop: "2026-10-20 15:30:00", partner_ids: [[6, 0, [12114]]] }],
         context: { no_mail_to_attendees: true } }],
      [{ vals_list: [{ name: "Escalation", start: "2026-10-20 14:00:00", stop: "2026-10-20 15:00:00", partner_ids: [[6, 0, [12114]]] }] }],
    ]);
  });

  it("will not write against something that is not an Odoo record", async () => {
    await expect(customer({ partnerMessagePost: vi.fn() }, "acme.com").addNote("x")).rejects.toThrow(/not an Odoo record id/);
  });
});
