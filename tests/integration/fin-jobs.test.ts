// Marco B — jobs (§17.2): início commitado, rollback completo do trabalho financeiro,
// falha persistente sem valores, processo morto → abandoned, trava contra execução paralela,
// recorrência idempotente. Oráculos O11 (via job), O32, O33/O40. Conexões reais (CALL com COMMIT).
import { randomUUID } from "node:crypto";
import pg from "pg";
import type { SupabaseClient } from "@supabase/supabase-js";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createActiveUser, env, signIn, sql, testEmail } from "./support";

let luck: SupabaseClient;
let owner: string;
let cycle: { id: string; closes_on: string };
const job = "close_due_cycles";

const dayAfter = (d: string) => {
  const x = new Date(`${d}T12:00:00Z`);
  x.setUTCDate(x.getUTCDate() + 1);
  return x.toISOString().slice(0, 10);
};

async function call(name: string, settings: Record<string, string> = {}) {
  const client = new pg.Client({ connectionString: env.dbUrl });
  await client.connect();
  try {
    for (const [k, v] of Object.entries(settings)) await client.query(`select set_config($1, $2, false)`, [k, v]);
    await client.query("call private.run_job($1)", [name]);
  } finally {
    await client.end();
  }
}

const lastRun = async (name: string) =>
  (await sql<{ status: string; error: string | null; items: number; finished_at: string | null }>(
    "select status, error, items, finished_at from public.job_runs where job = $1 order by started_at desc limit 1", [name]))[0];

beforeAll(async () => {
  owner = await createActiveUser(testEmail("fin-jobs"));
  luck = await signIn(testEmail("fin-jobs"));
  const { data: catRow } = await luck.from("categories").select("id").is("owner_user_id", null).eq("name", "Mercado").single();
  const { data: card } = await luck.rpc("create_card", {
    p_op: randomUUID(), p_owner: owner, p_name: "Cartão jobs", p_closing_day: 5, p_due_day: 15,
  });
  const today = new Date().toLocaleDateString("sv-SE", { timeZone: "America/Sao_Paulo" });
  const { error } = await luck.rpc("create_card_purchase", {
    p_op: randomUUID(), p_card: card.id, p_amount_cents: 12_345, p_installments: 1,
    p_description: "Compra", p_category: catRow!.id, p_local_date: today,
  });
  if (error) throw error;
  [cycle] = await sql<{ id: string; closes_on: string }>(
    "select id, to_char(closes_on, 'YYYY-MM-DD') as closes_on from public.billing_cycles where card_id = $1", [card.id]);
});

afterAll(async () => {
  // não deixa execução órfã que afete outras suítes
  await sql("update public.job_runs set status = 'abandoned', finished_at = now() where status = 'running'");
});

describe("Jobs", () => {
  it("O40/O33: falha no meio → nenhuma alteração financeira; falha registrada sem valores", async () => {
    await call(job, { "fluvi.today": dayAfter(cycle.closes_on), "fluvi.failpoint": job });
    const run = await lastRun(job);
    expect(run.status).toBe("failed");
    expect(run.error).toBe("P0001 failpoint");          // sanitizado: só código e marcador
    expect(run.finished_at).not.toBeNull();
    const [c] = await sql<{ status: string }>("select status from public.billing_cycles where id = $1", [cycle.id]);
    expect(c.status).toBe("open");                      // fechamento desfeito
    const [o] = await sql<{ n: number }>("select count(*)::int as n from public.obligations where billing_cycle_id = $1", [cycle.id]);
    expect(o.n).toBe(0);                                // nenhuma fatura parcial
  });

  it("O40: processo morto deixa 'running'; a execução seguinte marca 'abandoned' e conclui", async () => {
    const [dead] = await sql<{ id: string }>(
      "insert into public.job_runs (job, status, started_at) values ($1, 'running', now() - interval '2 hours') returning id", [job]);
    await call(job, { "fluvi.today": dayAfter(cycle.closes_on) });
    const [d] = await sql<{ status: string }>("select status from public.job_runs where id = $1", [dead.id]);
    expect(d.status).toBe("abandoned");
    const run = await lastRun(job);
    expect(run.status).toBe("succeeded");
    expect(run.items).toBeGreaterThanOrEqual(1);
    const [c] = await sql<{ status: string }>("select status from public.billing_cycles where id = $1", [cycle.id]);
    expect(c.status).toBe("closed");
  });

  it("O32: execução concorrente do mesmo job é registrada como 'skipped' e não faz nada", async () => {
    const holder = new pg.Client({ connectionString: env.dbUrl });
    await holder.connect();
    try {
      await holder.query("select pg_advisory_lock(hashtext($1))", [`fluvi.job.${job}`]);
      await call(job);
      expect((await lastRun(job)).status).toBe("skipped");
    } finally {
      await holder.query("select pg_advisory_unlock(hashtext($1))", [`fluvi.job.${job}`]);
      await holder.end();
    }
  });

  it("O11 via job: gerar recorrências duas vezes não duplica", async () => {
    const { data: catRow } = await luck.from("categories").select("id").is("owner_user_id", null).eq("name", "Assinaturas").single();
    const { error } = await luck.rpc("create_recurrence_rule", {
      p_op: randomUUID(), p_owner: owner, p_kind: "bill", p_description: "Streaming", p_category: catRow!.id,
      p_amount_cents: 4_990, p_frequency: "monthly", p_day_of_month: 10, p_start_date: "2026-01-01",
    });
    expect(error).toBeNull();
    await call("generate_recurrences");
    expect((await lastRun("generate_recurrences")).status).toBe("succeeded");
    const [before] = await sql<{ n: number }>("select count(*)::int as n from public.recurrence_occurrences where owner_user_id = $1", [owner]);
    expect(before.n).toBeGreaterThan(0);
    await call("generate_recurrences");
    const [after] = await sql<{ n: number }>("select count(*)::int as n from public.recurrence_occurrences where owner_user_id = $1", [owner]);
    expect(after.n).toBe(before.n);
    expect((await lastRun("generate_recurrences")).items).toBe(0);
  });
});
