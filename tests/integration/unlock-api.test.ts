// v2.2 R3 — desbloqueio financeiro pela API real (Auth + PostgREST), PRIV-02/04/06/07/09:
// sessão de login sozinha não lê dados financeiros; o desbloqueio é por sessão e família.
import { randomUUID } from "node:crypto";
import type { SupabaseClient } from "@supabase/supabase-js";
import { beforeAll, describe, expect, it } from "vitest";
import { anonClient, createFinanceUser, env, PASSWORD, signIn, testEmail } from "./support";

const email = testEmail("unlock-api");
let family: string;
let user: SupabaseClient;
let account: string;
let category: string;

const today = () => new Date().toLocaleDateString("sv-SE", { timeZone: "America/Sao_Paulo" });
const visible = async (c: SupabaseClient) => {
  const [acc, txn] = await Promise.all([
    c.from("financial_accounts").select("id"),
    c.from("transactions").select("id"),
  ]);
  return (acc.data?.length ?? 0) + (txn.data?.length ?? 0);
};
// Leitura direta pelo PostgREST com um access token específico (ex.: o de antes do logout).
async function restWith(token: string) {
  const res = await fetch(`${env.apiUrl}/rest/v1/financial_accounts?select=id`, {
    headers: { apikey: env.anonKey, Authorization: `Bearer ${token}` },
  });
  return { status: res.status, rows: res.ok ? ((await res.json()) as unknown[]) : [] };
}
const tokenOf = async (c: SupabaseClient) => (await c.auth.getSession()).data.session!.access_token;

beforeAll(async () => {
  family = await createFinanceUser(email);
  user = await signIn(email);
  const options = await user.rpc("quick_entry_options", { p_family: family });
  category = (options.data.categories as { id: string; name: string }[]).find((c) => c.name === "Mercado")!.id;
  account = (await user.rpc("create_account", {
    p_op: randomUUID(), p_family: family, p_name: "Banco", p_type: "checking",
    p_opening_date: "2026-01-01", p_opening_balance_cents: 100_000,
  })).data.id;
});

describe("Desbloqueio financeiro no servidor (PostgREST real)", () => {
  it("PRIV-09: logado sem desbloqueio não lê nada; o lançamento rápido grava e só devolve {id, status}", async () => {
    expect(await visible(user)).toBe(0);
    expect((await user.from("v_account_balances").select("*")).data).toEqual([]);
    const created = await user.rpc("create_transaction", {
      p_op: randomUUID(), p_family: family, p_type: "expense", p_account: account, p_amount_cents: 1500,
      p_description: "Farmácia", p_category: category, p_local_date: today(),
    });
    expect(created.error).toBeNull();
    expect(Object.keys(created.data).sort()).toEqual(["id", "status"]);
    const options = await user.rpc("quick_entry_options", { p_family: family });
    expect(Object.keys(options.data.accounts[0]).sort()).toEqual(["id", "name"]);
    expect((await user.rpc("finance_status")).data).toEqual({ unlocked: false });
  });

  it("PRIV-04: desbloqueio com a senha recém-digitada libera a leitura e sobrevive à renovação do token", async () => {
    const fresh = await signIn(email);            // mesma senha de novo: nova sessão, amr recente
    expect((await fresh.rpc("unlock_finance", { p_family: family })).error).toBeNull();
    expect(await visible(fresh)).toBe(2);         // conta + lançamento
    expect((await fresh.auth.refreshSession()).error).toBeNull();
    expect(await visible(fresh)).toBe(2);         // mesma sessão, ainda dentro da janela
    expect(await visible(user)).toBe(0);          // a outra sessão continua bloqueada
    expect((await fresh.rpc("touch_finance")).data).toBe(true);

    expect((await fresh.rpc("lock_finance")).error).toBeNull();
    expect(await visible(fresh)).toBe(0);         // bloqueio manual
    expect((await fresh.rpc("whoami")).data).toMatchObject({ status: "active" });  // login segue
  });

  it("PRIV-07: após o logout, o access token antigo não lê nada (mesmo antes de expirar)", async () => {
    const c = await signIn(email);
    expect((await c.rpc("unlock_finance", { p_family: family })).error).toBeNull();
    const token = await tokenOf(c);
    expect((await restWith(token)).rows).toHaveLength(1);
    await c.auth.signOut({ scope: "local" });
    const after = await restWith(token);
    expect(after.rows).toEqual([]);
  });

  it("PRIV-07: troca de senha invalida o desbloqueio", async () => {
    const c = await signIn(email);
    expect((await c.rpc("unlock_finance", { p_family: family })).error).toBeNull();
    expect(await visible(c)).toBe(2);
    const token = await tokenOf(c);
    expect((await c.auth.updateUser({ password: `${PASSWORD}-nova` })).error).toBeNull();
    expect((await restWith(token)).rows).toEqual([]);
    expect((await c.auth.updateUser({ password: PASSWORD })).error).toBeNull();
  });

  it("PRIV-10 e família alheia: quem não é membro não desbloqueia", async () => {
    const other = testEmail("unlock-api-outro");
    await createFinanceUser(other);
    const c = await signIn(other);
    const r = await c.rpc("unlock_finance", { p_family: family });
    expect(r.error?.code).toBe("P0002");
    expect((await c.rpc("quick_entry_options", { p_family: family })).error?.code).toBe("P0002");
    const anon = anonClient();
    expect((await anon.rpc("unlock_finance", { p_family: family })).error).not.toBeNull();
  });
});
