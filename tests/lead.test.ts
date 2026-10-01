import { describe, it, expect, vi } from "vitest";
import { entityForTest, mockGateway } from "@embabel/runtime-types";
import type { GenericGatewayContext } from "@embabel/runtime-types";
import { OdooLead } from "../src/api/lead";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function lead(odoo: Record<string, (args: any) => any>) {
  return entityForTest(OdooLead, { id: "4054", name: "Wayne Enterprises - Renewal" }, mockGateway<GenericGatewayContext>({ odoo }));
}

describe("OdooLead", () => {
  it("schedules a follow-up on the deal", async () => {
    const leadActivitySchedule = vi.fn(async () => [12]);
    expect(await lead({ leadActivitySchedule }).scheduleFollowUp({ summary: "Send the revised quote", due: "2026-10-18" })).toBe(12);
    expect(leadActivitySchedule).toHaveBeenCalledWith({
      ids: [4054], summary: "Send the revised quote", date_deadline: "2026-10-18", act_type_xmlid: "mail.mail_activity_data_todo",
    });
  });

  it("updates the named fields and nothing else, and refuses an empty update", async () => {
    const leadWrite = vi.fn(async () => true);
    expect(await lead({ leadWrite }).update({ probability: 20 })).toBe(true);
    expect(leadWrite).toHaveBeenCalledWith({ ids: [4054], vals: { probability: 20 } });
    await expect(lead({ leadWrite }).update({})).rejects.toThrow(/at least one field/);
  });
});
