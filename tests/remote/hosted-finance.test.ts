// Deploy do Marco B no fluvi-dev (plano §2.4.3): fluxo financeiro pela API hospedada,
// com JWT real e identidades FICTÍCIAS. Confere EQ-1 e isolamento entre titulares.
// Identidades com histórico financeiro não são apagáveis (razão somente-acréscimo):
// ao final são BLOQUEADAS (plano D-3; anonimização é o C-4).
//   FLUVI_REMOTE_URL, FLUVI_REMOTE_ANON_KEY, FLUVI_REMOTE_SERVICE_KEY, FLUVI_REMOTE_DB_URL (projeto DEV)
import { randomUUID } from "node:crypto";
import pg from "pg";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

const url = process.env.FLUVI_REMOTE_URL ?? "";
const anonKey = process.env.FLUVI_REMOTE_ANON_KEY ?? "";
const serviceKey = process.env.FLUVI_REMOTE_SERVICE_KEY ?? "";
const dbUrl = process.env.FLUVI_REMOTE_DB_URL ?? "";
if (!/^https:\/\/[a-z]{20}\.supabase\.co$/.test(url) || !anonKey || !serviceKey || !dbUrl.includes("pooler.supabase.com")) {
  throw new Error("defina FLUVI_REMOTE_URL/ANON_KEY/SERVICE_KEY/DB_URL do projeto de DESENVOLVIMENTO");
}

const noPersist = { auth: { persistSession: false, autoRefreshToken: false } };
const service = createClient(url, serviceKey, noPersist);
const run = randomUUID().slice(0, 8);
const PASSWORD = "Fluvi-Remoto-2026-Forte";
const today = new Date().toLocaleDateString("sv-SE", { timeZone: "America/Sao_Paulo" });
const ids: Record<string, string> = {};
let a: SupabaseClient;
let b: SupabaseClient;

async function sql<T>(text: string, params: unknown[] = []): Promise<T[]> {
  const c = new pg.Client({ connectionString: dbUrl });
  await c.connect();
  try { return (await c.query(text, params)).rows as T[]; } finally { await c.end(); }
}

async function fictitious(name: string): Promise<{ id: string; client: SupabaseClient }> {
  const email = `${name}.${run}@fluvi.test`;
  const { data, error } = await service.auth.admin.createUser({ email, password: PASSWORD, email_confirm: true });
  if (error) throw error;
  const upd = await service.from("profiles").update({
    provisioned_at: new Date().toISOString(), status: "active", activation_completed_at: new Date().toISOString(),
  }).eq("user_id", data.user.id);
  if (upd.error) throw upd.error;
  const client = createClient(url, anonKey, noPersist);
  const login = await client.auth.signInWithPassword({ email, password: PASSWORD });
  if (login.error) throw login.error;
  return { id: data.user.id, client };
}

async function must(client: SupabaseClient, fn: string, args: Record<string, unknown>) {
  const { data, error } = await client.rpc(fn, args);
  if (error) throw new Error(`${fn}: ${error.code} ${error.message}`);
  return data as { id: string };
}

const eq = async (card: string) =>
  Number((await sql<{ d: string }>("select difference_cents as d from private.card_reconciliation($1)", [card]))[0].d);

beforeAll(async () => {
  ({ id: ids.a, client: a } = await fictitious("remoto-fin-a"));
  ({ id: ids.b, client: b } = await fictitious("remoto-fin-b"));
  const { data } = await a.from("categories").select("id, name").is("owner_user_id", null);
  ids.cat = data!.find((c) => c.name === "Mercado")!.id;
  ids.bill = data!.find((c) => c.name === "Moradia")!.id;
});

afterAll(async () => {
  for (const id of [ids.a, ids.b].filter(Boolean)) {
    await service.from("profiles").update({ status: "blocked" }).eq("user_id", id);
  }
});

describe("Marco B no fluvi-dev (API hospedada)", () => {
  it("conta, cartão, compra parcelada, estorno e anulação mantêm a EQ-1", async () => {
    ids.acc = (await must(a, "create_account", { p_op: randomUUID(), p_owner: ids.a, p_name: "Banco", p_type: "checking",
      p_opening_date: "2026-01-01", p_opening_balance_cents: 1_000_000 })).id;
    ids.card = (await must(a, "create_card", { p_op: randomUUID(), p_owner: ids.a, p_name: "Cartão", p_closing_day: 5,
      p_due_day: 15 })).id;
    const purchase = (await must(a, "create_card_purchase", { p_op: randomUUID(), p_card: ids.card, p_amount_cents: 120_000,
      p_installments: 6, p_description: "Compra 6x", p_category: ids.cat, p_local_date: today })).id;
    expect(await eq(ids.card)).toBe(0);
    await must(a, "refund_transaction", { p_op: randomUUID(), p_transaction: purchase, p_amount_cents: 50_000, p_refunded_on: today });
    expect(await eq(ids.card)).toBe(0);
    const extra = (await must(a, "create_card_purchase", { p_op: randomUUID(), p_card: ids.card, p_amount_cents: 5_000,
      p_installments: 1, p_description: "Engano", p_category: ids.cat, p_local_date: today })).id;
    await must(a, "void_transaction", { p_op: randomUUID(), p_transaction: extra, p_reason: "lançada por engano" });
    expect(await eq(ids.card)).toBe(0);

    const { data: pos } = await a.from("v_card_position").select("debt_total_cents").eq("card_id", ids.card).single();
    expect(Number(pos!.debt_total_cents)).toBe(70_000);
  });

  it("conta a pagar com pagamento parcial: competência reconhecida, caixa só o pago", async () => {
    const obl = (await must(a, "create_obligation", { p_op: randomUUID(), p_owner: ids.a, p_type: "bill",
      p_description: "Aluguel", p_category: ids.bill, p_amount_cents: 50_000, p_due_date: today })).id;
    await must(a, "settle_obligation", { p_op: randomUUID(), p_obligation: obl, p_account: ids.acc,
      p_amount_cents: 20_000, p_paid_on: today });
    const { data: st } = await a.from("v_obligations_status").select("remaining_cents, settlement_status").eq("id", obl).single();
    expect(Number(st!.remaining_cents)).toBe(30_000);
    expect(st!.settlement_status).toBe("partial");
    const { data: bal } = await a.rpc("account_balance", { p_account: ids.acc });
    expect(Number(bal)).toBe(1_000_000 - 20_000);
  });

  it("idempotência: a mesma client_operation_id 3× gera uma operação", async () => {
    const op = randomUUID();
    for (let i = 0; i < 3; i++) {
      await must(a, "create_transaction", { p_op: op, p_owner: ids.a, p_type: "expense", p_account: ids.acc,
        p_amount_cents: 1_234, p_description: "Repetida", p_category: ids.cat, p_local_date: today });
    }
    const [row] = await sql<{ n: number }>(
      "select count(*)::int as n from public.transactions where owner_user_id = $1 and client_operation_id = $2", [ids.a, op]);
    expect(row.n).toBe(1);
  });

  it("isolamento: outro titular sem grant não lê nem escreve, e recebe o erro único", async () => {
    const write = await b.rpc("create_transaction", { p_op: randomUUID(), p_owner: ids.a, p_type: "expense",
      p_account: ids.acc, p_amount_cents: 100, p_description: "x", p_category: ids.cat, p_local_date: today });
    expect(write.error?.code).toBe("P0002");
    const ghost = await b.rpc("create_transaction", { p_op: randomUUID(), p_owner: ids.b, p_type: "expense",
      p_account: randomUUID(), p_amount_cents: 100, p_description: "x", p_category: ids.cat, p_local_date: today });
    expect(ghost.error?.code).toBe("P0002");
    for (const table of ["transactions", "financial_accounts", "ledger_entries", "credit_cards", "obligations"]) {
      const { data } = await b.from(table).select("*").limit(5);
      expect(data, table).toEqual([]);
    }
    const anon = createClient(url, anonKey, noPersist);
    const anonRead = await anon.from("transactions").select("id").limit(1);
    expect(anonRead.error?.code).toBe("42501");
  });
});
