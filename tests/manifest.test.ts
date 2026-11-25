/*
 * The host checks every handler call against dist/manifest.json, input and output, and refuses
 * one that does not match — and refuses outright a schema naming a type JSON Schema does not have.
 * `bookCall`'s optional `sendInvitation` was published as `{ type: "undefined" }` twice over, so
 * every booking was refused before it reached Odoo, whatever it asked for.
 *
 * Each method runs against a mocked Odoo, and both the call and what it sends back are held to the
 * schemas the manifest publishes for it.
 */
import { readFileSync } from "node:fs";
import Ajv from "ajv";
import { describe, expect, it } from "vitest";
import { entityForTest, mockGateway } from "@embabel/runtime-types";
import type { OdooWriteGateway } from "../src/api/odoo";
import { OdooCustomer } from "../src/api/odoo-customer";
import { OdooLead } from "../src/api/odoo-lead";

type Entry = { namespace: string; name: string; onType?: string; inputSchema: object; outputSchema: object };
const manifest = JSON.parse(readFileSync("dist/manifest.json", "utf8")) as { entries: Entry[] };
const ajv = new Ajv({ allErrors: true });

const entry = (onType: string, name: string): Entry => {
  const e = manifest.entries.find((x) => x.onType === onType && x.name === name);
  if (!e) throw new Error(`no manifest entry for ${onType}.${name}`);
  return e;
};

/** Held to the published schema exactly as the host holds it: through JSON. */
const admitted = (schema: object, value: unknown): string[] => {
  const check = ajv.compile(schema);
  return check(JSON.parse(JSON.stringify(value ?? null))) ? [] : (check.errors ?? []).map((e) => `${e.instancePath} ${e.message}`);
};

const types = (schema: unknown): string[] =>
  !schema || typeof schema !== "object" ? []
    : Object.entries(schema).flatMap(([k, v]) => (k === "type" && (typeof v === "string" || Array.isArray(v)) ? [v].flat() : types(v)));

const odoo = {
  partnerMessagePost: async () => [54603],
  partnerActivitySchedule: async () => [7],
  leadActivitySchedule: async () => [8],
  calendarEventCreate: async () => [91],
  leadWrite: async () => true,
};
const gateway = mockGateway<OdooWriteGateway>({ odoo } as unknown as Partial<OdooWriteGateway>);
const customer = () => entityForTest(OdooCustomer, { id: "12114", name: "Acme Corporation" }, gateway);
const lead = () => entityForTest(OdooLead, { id: "301", name: "Renewal" }, gateway);

describe("the published schemas", () => {
  it("use only JSON Schema types", () => {
    const allowed = new Set(["null", "boolean", "object", "array", "number", "integer", "string"]);
    for (const e of manifest.entries) {
      expect(types(e.inputSchema).filter((t) => !allowed.has(t)), `${e.name} input`).toEqual([]);
      expect(types(e.outputSchema).filter((t) => !allowed.has(t)), `${e.name} output`).toEqual([]);
    }
  });

  it("compile, every one", () => {
    for (const e of manifest.entries) {
      expect(() => ajv.compile(e.inputSchema), `${e.name} input`).not.toThrow();
      expect(() => ajv.compile(e.outputSchema), `${e.name} output`).not.toThrow();
    }
  });
});

/*
 * A namespace two installed realms both contribute is withdrawn from both, every function in it,
 * so a name another realm could also choose ("customer", "lead") takes this realm's methods away
 * whenever that realm is installed beside it. The namespace is the file's name under src/api/.
 */
describe("the namespaces", () => {
  it("are this realm's own", () => {
    expect([...new Set(manifest.entries.map((e) => e.namespace))].sort()).toEqual(["odoo_customer", "odoo_lead"]);
  });
});

describe("each method's call and reply, against its own schema", () => {
  it.each([
    ["OdooCustomer", "addNote", "Payment failed twice", () => customer().addNote("Payment failed twice")],
    ["OdooCustomer", "scheduleFollowUp", { summary: "Call about renewal", due: "2026-10-16", kind: "call" },
      () => customer().scheduleFollowUp({ summary: "Call about renewal", due: "2026-10-16", kind: "call" })],
    ["OdooCustomer", "bookCall", { title: "Escalation", start: "2026-10-20T10:00:00Z", sendInvitation: true },
      () => customer().bookCall({ title: "Escalation", start: "2026-10-20T10:00:00Z", sendInvitation: true })],
    ["OdooCustomer", "bookCall", { title: "Renewal call", start: "2026-10-20T15:00:00", sendInvitation: false },
      () => customer().bookCall({ title: "Renewal call", start: "2026-10-20T15:00:00", sendInvitation: false })],
    ["OdooLead", "scheduleFollowUp", { summary: "Chase", due: "2026-10-15" },
      () => lead().scheduleFollowUp({ summary: "Chase", due: "2026-10-15" })],
    ["OdooLead", "update", { probability: 60 }, () => lead().update({ probability: 60 })],
  ] as const)("%s.%s", async (onType, name, args, call) => {
    const e = entry(onType, name);
    expect(admitted(e.inputSchema, args), "input").toEqual([]);
    expect(admitted(e.outputSchema, await call()), "output").toEqual([]);
  });
});
