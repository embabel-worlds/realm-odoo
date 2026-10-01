import { Entity } from "@embabel/runtime-types";
import { activityArgs, odooId, type FollowUp, type OdooWriteGateway } from "./odoo";

/** An opportunity in Odoo (`crm.lead`), with what can be done to it once found. */
export class OdooLead extends Entity {
  name?: string;
  expected_revenue?: number;
  probability?: number;

  private get api(): OdooWriteGateway {
    return this.gateway as unknown as OdooWriteGateway;
  }

  /** Schedule follow-up work on the deal, due on a date, optionally assigned to someone. */
  async scheduleFollowUp(followUp: FollowUp): Promise<number> {
    const ids = await this.api.odoo.leadActivitySchedule(activityArgs(odooId(this.id), followUp));
    return ids[0];
  }

  /**
   * Overwrite fields on the deal: stage, expected revenue, probability, close date. What was there
   * is not kept, so this is the call a world is most likely to refuse.
   */
  async update(fields: Record<string, unknown>): Promise<boolean> {
    if (Object.keys(fields).length === 0) throw new Error("update needs at least one field");
    return this.api.odoo.leadWrite({ ids: [odooId(this.id)], vals: fields });
  }
}
