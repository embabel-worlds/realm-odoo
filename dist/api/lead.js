"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.OdooLead = void 0;
const runtime_types_1 = require("@embabel/runtime-types");
const odoo_1 = require("./odoo");
/** An opportunity in Odoo (`crm.lead`), with what can be done to it once found. */
class OdooLead extends runtime_types_1.Entity {
    name;
    expected_revenue;
    probability;
    /** Schedule follow-up work on the deal, due on a date, optionally assigned to someone. */
    async scheduleFollowUp(followUp) {
        const ids = await this.gateway.odoo.leadActivitySchedule((0, odoo_1.activityArgs)((0, odoo_1.odooId)(this.id), followUp));
        return ids[0];
    }
    /**
     * Overwrite fields on the deal: stage, expected revenue, probability, close date. What was there
     * is not kept, so this is the call a world is most likely to refuse.
     */
    async update(fields) {
        if (Object.keys(fields).length === 0)
            throw new Error("update needs at least one field");
        return this.gateway.odoo.leadWrite({ ids: [(0, odoo_1.odooId)(this.id)], vals: fields });
    }
}
exports.OdooLead = OdooLead;
