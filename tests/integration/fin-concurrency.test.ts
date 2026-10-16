// Marco B — concorrência real (§11.1, §17.4): requisições paralelas pela API (PostgREST)
// com JWT real. Oráculos O13, O24, O16 (paralelo) e O34. Dados fictícios.
// Identidades com histórico financeiro não são apagadas (razão somente-acréscimo);
// cada execução usa e-mails únicos.
import { randomUUID } from "node:crypto";
import pg from "pg";
import type { SupabaseClient } from "@supabase/supabase-js";
import { beforeAll, describe, expect, it } from "vitest";
import { createFinanceUser, env, signIn, sql, testEmail } from "./support";

// Sessão SQL agindo como o usuário (mesmo papel e claims que o PostgREST usa), com
// transação explícita: permite segurar A aberta enquanto B tenta — sobreposição garantida.
async function userTx(ownerId: string) {
  const c = new pg.Client({ connectionString: env.dbUrl });
  await c.connect();
  await c.query("begin");
  await c.query("select set_config('request.jwt.claims', $1, true)",
    [JSON.stringify({ sub: ownerId, role: "authenticated", aal: "aal1" })]);
  await c.query("set local role authenticated");
  return c;
}

// A executa e segura a transação; B tenta a mesma operação. Com trava, B espera A e é recusada.
async function overlap(ownerId: string, sqlText: string, params: () => unknown[]) {
  const a = await userTx(ownerId);
  const b = await userTx(ownerId);
  try {
    await a.query(sqlText, params());
    let bDone = false;
    const bResult = b.query(sqlText, params()).then(
      () => { bDone = true; return null; },
      (e: { code?: string }) => { bDone = true; return e; });
    await new Promise((r) => setTimeout(r, 500));
    const bWaited = !bDone;            // B precisa estar bloqueada pela trava de A
    await a.query("commit");
    const bError = await bResult;
    await b.query(bError ? "rollback" : "commit");
    return { bWaited, bError };
  } finally {
    await a.end();
    await b.end();
  }
}

let luck: SupabaseClient;
let owner: string;
let account: string;
let cat: string;

const today = () => new Date().toLocaleDateString("sv-SE", { timeZone: "America/Sao_Paulo" });

async function rpc<T = Record<string, unknown>>(fn: string, args: Record<string, unknown>) {
  const { data, error } = await luck.rpc(fn, args);
  return { data: data as T, error };
}

async function must<T = { id: string }>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await rpc<T>(fn, args);
  if (error) throw new Error(`${fn}: ${error.code} ${error.message}`);
  return data;
}

async function reconciliation(card: string) {
  const [row] = await sql<{ difference_cents: string }>(
    "select difference_cents from private.card_reconciliation($1)", [card]);
  return Number(row.difference_cents);
}

beforeAll(async () => {
  owner = await createFinanceUser(testEmail("fin-conc"));
  luck = await signIn(testEmail("fin-conc"));
  account = (await must("create_account", {
    p_op: randomUUID(), p_family: owner, p_name: "Banco", p_type: "checking",
    p_opening_date: "2026-01-01", p_opening_balance_cents: 10_000_000,
  })).id;
  const { data } = await luck.from("categories").select("id").is("family_id", null).eq("name", "Mercado").single();
  cat = data!.id;
});

describe("Concorrência determinística (transações sobrepostas)", () => {
  it("O13: pagamento B espera a trava de A e é recusado por exceder o devido", async () => {
    const obl = (await must("create_obligation", {
      p_op: randomUUID(), p_family: owner, p_type: "bill", p_description: "Conta det", p_category: cat,
      p_amount_cents: 50_000, p_due_date: today(),
    })).id;
    const r = await overlap(owner, "select public.settle_obligation($1, $2, $3, 30000, $4)",
      () => [randomUUID(), obl, account, today()]);
    expect(r.bWaited).toBe(true);
    expect(r.bError?.code).toBe("23514");
    const [row] = await sql<{ paid: string }>("select private.obligation_paid($1) as paid", [obl]);
    expect(Number(row.paid)).toBe(30_000);
  });

  it("O24: estorno B espera a trava de A e é recusado por exceder o estornável; EQ-1 = 0", async () => {
    const card = (await must("create_card", {
      p_op: randomUUID(), p_family: owner, p_name: "Cartão det", p_closing_day: 5, p_due_day: 15,
    })).id;
    const purchase = (await must("create_card_purchase", {
      p_op: randomUUID(), p_card: card, p_amount_cents: 30_000, p_installments: 1,
      p_description: "Compra det", p_category: cat, p_local_date: today(),
    })).id;
    const r = await overlap(owner, "select public.refund_transaction($1, $2, 20000, $3)",
      () => [randomUUID(), purchase, today()]);
    expect(r.bWaited).toBe(true);
    expect(r.bError?.code).toBe("23514");
    expect(await reconciliation(card)).toBe(0);
  });
});

describe("Concorrência real pela API (estresse)", () => {
  it("O13: 2 pagamentos simultâneos de R$ 300 numa obrigação de R$ 500 → um aceito", async () => {
    const obl = (await must("create_obligation", {
      p_op: randomUUID(), p_family: owner, p_type: "bill", p_description: "Conta", p_category: cat,
      p_amount_cents: 50_000, p_due_date: today(),
    })).id;
    const results = await Promise.all([1, 2].map(() => rpc("settle_obligation", {
      p_op: randomUUID(), p_obligation: obl, p_account: account, p_amount_cents: 30_000, p_paid_on: today(),
    })));
    expect(results.filter((r) => !r.error)).toHaveLength(1);
    expect(results.filter((r) => r.error?.code === "23514")).toHaveLength(1);
    const { data } = await luck.from("v_obligations_status").select("remaining_cents").eq("id", obl).single();
    expect(Number(data!.remaining_cents)).toBe(20_000);
  });

  it("O13b: 10 pagamentos simultâneos de R$ 100 numa obrigação de R$ 500 → exatamente 5", async () => {
    const obl = (await must("create_obligation", {
      p_op: randomUUID(), p_family: owner, p_type: "bill", p_description: "Conta 2", p_category: cat,
      p_amount_cents: 50_000, p_due_date: today(),
    })).id;
    const results = await Promise.all(Array.from({ length: 10 }, () => rpc("settle_obligation", {
      p_op: randomUUID(), p_obligation: obl, p_account: account, p_amount_cents: 10_000, p_paid_on: today(),
    })));
    expect(results.filter((r) => !r.error)).toHaveLength(5);
    const { data } = await luck.from("v_obligations_status").select("remaining_cents, settlement_status").eq("id", obl).single();
    expect(Number(data!.remaining_cents)).toBe(0);
    expect(data!.settlement_status).toBe("paid");
  });

  it("O24: 2 estornos simultâneos de R$ 200 numa compra de R$ 300 → um aceito; EQ-1 = 0", async () => {
    const card = (await must("create_card", {
      p_op: randomUUID(), p_family: owner, p_name: "Cartão C", p_closing_day: 5, p_due_day: 15,
    })).id;
    const purchase = (await must("create_card_purchase", {
      p_op: randomUUID(), p_card: card, p_amount_cents: 30_000, p_installments: 1,
      p_description: "Compra", p_category: cat, p_local_date: today(),
    })).id;
    const results = await Promise.all([1, 2].map(() => rpc("refund_transaction", {
      p_op: randomUUID(), p_transaction: purchase, p_amount_cents: 20_000, p_refunded_on: today(),
    })));
    expect(results.filter((r) => !r.error)).toHaveLength(1);
    expect(results.filter((r) => r.error?.code === "23514")).toHaveLength(1);
    expect(await reconciliation(card)).toBe(0);
  });

  it("O16 em paralelo: mesma client_operation_id 10× simultâneas → uma operação", async () => {
    const op = randomUUID();
    const results = await Promise.all(Array.from({ length: 10 }, () => rpc<{ id: string }>("create_transaction", {
      p_op: op, p_family: owner, p_type: "expense", p_account: account, p_amount_cents: 777,
      p_description: "Paralela", p_category: cat, p_local_date: today(),
    })));
    const ok = results.filter((r) => !r.error);
    expect(ok.length).toBeGreaterThanOrEqual(1);
    expect(new Set(ok.map((r) => r.data.id)).size).toBe(1);
    expect(results.filter((r) => r.error).every((r) => r.error!.code === "23505")).toBe(true);
    const rows = await sql<{ n: number }>(
      "select count(*)::int as n from public.transactions where family_id = $1 and client_operation_id = $2", [owner, op]);
    expect(rows[0].n).toBe(1);
  });

  it("O34: ajuste de parcelas concorrente com pagamento da fatura → ambos consistentes; EQ-1 = 0", async () => {
    const card = (await must("create_card", {
      p_op: randomUUID(), p_family: owner, p_name: "Cartão O34", p_closing_day: 5, p_due_day: 15,
    })).id;
    const purchase = (await must("create_card_purchase", {
      p_op: randomUUID(), p_card: card, p_amount_cents: 120_000, p_installments: 6,
      p_description: "6x", p_category: cat, p_local_date: today(),
    })).id;
    // fecha o primeiro ciclo (como o job faria) para existir fatura a pagar
    const [first] = await sql<{ id: string }>(
      "select billing_cycle_id as id from public.installments i join public.card_purchases p on p.id = i.purchase_id where p.transaction_id = $1 and i.sequence = 1",
      [purchase]);
    const [obl] = await sql<{ id: string }>("select private.close_cycle($1) as id", [first.id]);

    const [adjust, pay] = await Promise.all([
      rpc("adjust_installments", { p_op: randomUUID(), p_purchase_transaction: purchase, p_new_total_cents: 110_000,
        p_remaining_count: 4, p_reason: "desconto" }),
      rpc("settle_obligation", { p_op: randomUUID(), p_obligation: obl.id, p_account: account,
        p_amount_cents: 20_000, p_paid_on: today() }),
    ]);
    expect(adjust.error).toBeNull();
    expect(pay.error).toBeNull();
    expect(await reconciliation(card)).toBe(0);
    const [sum] = await sql<{ s: string }>(
      "select sum(i.amount_cents) as s from public.installments i join public.card_purchases p on p.id = i.purchase_id where p.transaction_id = $1 and i.status = 'valid'",
      [purchase]);
    expect(Number(sum.s)).toBe(110_000);
  });
});
